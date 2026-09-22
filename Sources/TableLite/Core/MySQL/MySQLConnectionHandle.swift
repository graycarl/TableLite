import Foundation
import Dispatch
import Darwin
import Synchronization
import CMySQLClient

/// `MySQLSession` 的底层句柄：包装一个 `MTLConn *`、它专用的串行队列，以及跨线程可读的
/// 取消标志 / `thread_id`。
///
/// `@unchecked Sendable` 的理由（`AGENTS.md` 允许的唯一例外：包装 C 指针）：
/// - `connection` 只在 `queue` 上被安装 / 取走，锁只为让 `cancel()` 这条例外路径能安全地读到指针；
/// - 取消标志与 `thread_id` 用 `Atomic`，`cancel()` 与查询循环可以无锁地并发读写；
/// - `mtl_conn_cancel` 是 C shim 明确允许跨线程调用的唯一函数（`01-architecture.md` §3.3）。
final class MySQLConnectionHandle: @unchecked Sendable {

    /// session 的专用串行队列，同时作为 `MySQLSession` 的 actor executor。
    let queue: DispatchSerialQueue

    private let queueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    /// 只在 `queue` 上安装 / 取走；`cancel()` 读它时持锁。
    private var connection: OpaquePointer?
    private var charset: String = "utf8mb4"

    private let cancelledFlag = Atomic<Bool>(false)
    private let timedOutFlag = Atomic<Bool>(false)
    private let serverThreadID = Atomic<UInt64>(0)

    init(label: String) {
        queue = DispatchSerialQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        if let connection = takeConnection() {
            mtl_conn_free(connection)
        }
    }

    // MARK: 连接句柄

    /// 当前是否运行在 session 的串行队列上。用于 `escape` 避免自死锁。
    var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == true }

    var pointer: OpaquePointer? { lock.withLock { connection } }

    func install(_ raw: OpaquePointer?) {
        lock.withLock { connection = raw }
    }

    /// 取走句柄并置空；调用方负责 `mtl_conn_free`。
    func takeConnection() -> OpaquePointer? {
        lock.withLock {
            let raw = connection
            connection = nil
            return raw
        }
    }

    var charsetName: String { lock.withLock { charset } }

    func setCharset(_ value: String) {
        lock.withLock { charset = value }
    }

    // MARK: 取消 / 超时

    var serverThreadIDValue: UInt64 { serverThreadID.load(ordering: .relaxed) }

    func setServerThreadID(_ value: UInt64) {
        serverThreadID.store(value, ordering: .relaxed)
    }

    var isCancelled: Bool { cancelledFlag.load(ordering: .relaxed) }

    var wasTimedOut: Bool { timedOutFlag.load(ordering: .relaxed) }

    /// 每次下发前清状态（C 侧 `mtl_conn_query` 也会清自己的标志）。
    func beginQuery() {
        cancelledFlag.store(false, ordering: .relaxed)
        timedOutFlag.store(false, ordering: .relaxed)
    }

    /// 置 C 侧取消标志，让取行循环尽快返回。可从任意线程调用。
    func requestCancel() {
        cancelledFlag.store(true, ordering: .relaxed)
        // 持锁调用，和 takeConnection() 互斥，避免对已释放的句柄调用。
        lock.withLock {
            if let connection {
                mtl_conn_cancel(connection)
            }
        }
    }

    func markTimedOut() {
        timedOutFlag.store(true, ordering: .relaxed)
    }

    // MARK: 转义

    /// 用连接的转义器把文本转义成字符串字面量的内部形式（不含首尾引号）。
    ///
    /// 这是 `SQLValueLiteral.StringEscaper` 的注入点：Preview 与正式下发共用同一条路径
    /// （`13-open-questions.md` S29）。在 session 队列上调用时直接走 C；否则投递到队列上串行执行。
    func escape(_ text: String) -> String {
        let bytes = Array(text.utf8)
        if isOnQueue {
            return escapeDirect(bytes)
        }
        return queue.sync { escapeDirect(bytes) }
    }

    private func escapeDirect(_ bytes: [UInt8]) -> String {
        guard let connection = lock.withLock({ connection }) else {
            // 没有连接时拿不到连接 charset，退化为最保守的纯函数转义。
            return SQLValueLiteral.escape(String(decoding: bytes, as: UTF8.self), mode: .mysqlDefault)
        }
        let input = bytes.map { CChar(bitPattern: $0) }
        var capacity = bytes.count * 2 + 16
        while true {
            var output = [CChar](repeating: 0, count: capacity)
            let written = input.withUnsafeBufferPointer { inputBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    mtl_conn_escape(connection, inputBuffer.baseAddress, bytes.count,
                                    outputBuffer.baseAddress, outputBuffer.count)
                }
            }
            if written < capacity {
                return String(decoding: output.prefix(written).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            // 缓冲区不足时 C 返回需要的长度。
            capacity = written + 1
        }
    }
}

// MARK: - KILL QUERY 控制连接

/// 懒创建、空闲 60s 关闭的控制连接，用于从独立连接发送 `KILL QUERY`（只杀语句，不杀连接）。
///
/// 见 `docs/tech-designs/03-mysql-layer.md` §5、`01-architecture.md` §3.3。
///
/// `@unchecked Sendable` 的理由：内部 `connection` 只在该类自己的串行队列上访问；
/// `parameters` 用锁保护；`kill` 从任意线程投递到该队列。
final class MySQLCancelTransport: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.graycarl.tablelite.mysql.cancel", qos: .userInitiated)
    private let lock = NSLock()
    private var parameters: MySQLConnectionParameters?
    /// 只在 `queue` 上访问。
    private var connection: OpaquePointer?
    private var generation: UInt64 = 0
    private let idleTimeout: TimeInterval = 60

    deinit {
        if let connection {
            mtl_conn_free(connection)
        }
    }

    func update(parameters: MySQLConnectionParameters?) {
        lock.withLock { self.parameters = parameters }
    }

    /// 关闭控制连接（切换连接 / 断开时调用）。异步投递，不阻塞调用方。
    func close() {
        queue.async { [self] in
            closeLocked()
        }
    }

    /// 发送 `KILL QUERY <threadID>`。失败时抛 `MySQLError`，由上层提示「取消失败，查询仍在运行」。
    ///
    /// `1094`（线程已结束）视为成功：查询可能刚好跑完了。
    func kill(threadID: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                var pending: Error?
                do {
                    let connection = try ensureConnection()
                    let sql = "KILL QUERY \(threadID)"
                    var errorBuffer = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
                    let rc = sql.withCString { pointer in
                        mtl_conn_query(connection, pointer, sql.utf8.count, 0, nil, &errorBuffer, errorBuffer.count)
                    }
                    if rc != MTL_OK {
                        let code = mtl_conn_errno(connection)
                        if code != 1094 {
                            let message = errorMessage(errorBuffer, connection: connection)
                            pending = MySQLError.server(
                                code: code,
                                sqlState: mysqlCString(mtl_conn_sqlstate(connection)),
                                message: message,
                                statement: sql
                            )
                        }
                    }
                    scheduleIdleClose()
                } catch {
                    pending = error
                }
                if let pending {
                    continuation.resume(throwing: pending)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: 内部（只在 queue 上调用）

    private func ensureConnection() throws -> OpaquePointer {
        if let connection, mtl_conn_is_open(connection) == 1 {
            return connection
        }
        closeLocked()
        guard let parameters = lock.withLock({ parameters }) else {
            throw MySQLError.notConnected(statement: "KILL QUERY")
        }
        guard let raw = mtl_conn_create() else {
            throw MySQLError(kind: .connectionFailed, code: 0, sqlState: "", message: "控制连接创建失败")
        }
        mtl_conn_set_ssl(raw, parameters.useSSL ? 1 : 0, parameters.skipCertificateVerification ? 1 : 0)
        mtl_conn_set_connect_timeout(raw, parameters.connectTimeoutSeconds)

        var errorBuffer = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        // 控制连接不需要选库，避免目标库不存在时连不上。
        let rc = mtl_conn_open(raw, parameters.host, parameters.port, parameters.user, parameters.password,
                               "", parameters.charset, parameters.unixSocket, &errorBuffer, errorBuffer.count)
        guard rc == MTL_OK else {
            let code = mtl_conn_errno(raw)
            let sqlState = mysqlCString(mtl_conn_sqlstate(raw))
            let message = errorMessage(errorBuffer, connection: raw)
            mtl_conn_free(raw)
            throw MySQLError.connectionFailure(code: code, sqlState: sqlState, message: message)
        }
        connection = raw
        return raw
    }

    private func scheduleIdleClose() {
        generation += 1
        let current = generation
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak self] in
            guard let self else { return }
            if self.generation == current {
                self.closeLocked()
            }
        }
    }

    private func closeLocked() {
        if let connection {
            mtl_conn_free(connection)
            self.connection = nil
        }
    }

    private func errorMessage(_ buffer: [CChar], connection: OpaquePointer) -> String {
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? mysqlCString(mtl_conn_error(connection)) : text
    }
}
