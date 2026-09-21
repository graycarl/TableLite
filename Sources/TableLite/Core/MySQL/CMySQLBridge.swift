import Foundation
import CMySQLClient

// MARK: - CMySQLBridge

/// 包装 `MTLConn *` 与一条专用串行队列。
///
/// 并发模型（硬约束）：见 `docs/tech-designs/01-architecture.md` §3
/// - 除 `requestCancel()`（转发到 C 层明确声明「可从任意线程调用」的 `mtl_conn_cancel`）
///   之外，所有 libmysqlclient 调用都在 `queue` 上串行执行；
/// - 跨队列读取的标量（open / threadID / needsReset）用 `stateLock` 保护。
///   调用 C 之前只把句柄指针在锁内复制出来，绝不在持锁状态下执行查询，
///   否则会与取消路径互锁。
///
/// `@unchecked Sendable` 的唯一理由：内部持有不可 Sendable 的 `MTLConn *`（C 指针）。
/// 线程安全由上述两条约定保证，符合 `AGENTS.md` 的唯一例外条款。
final class CMySQLBridge: @unchecked Sendable {

    // MARK: 参数与结果

    /// 建立连接所需的参数（来自 `MySQLSession.Configuration`，SSH 隧道场景下 host/port 已是本地端点）。
    struct OpenParameters: Sendable {
        var host: String
        var port: Int
        var user: String
        var password: String?
        var database: String
        var charset: String
        var useSSL: Bool
        var skipCertificateVerification: Bool
        var connectTimeout: Int
    }

    /// 连接握手阶段读到的服务器信息。
    struct Handshake: Sendable {
        var serverVersion: String
        var hostInfo: String
        var threadID: UInt64
    }

    /// 一次 `mtl_conn_query` 调用的终态。
    struct QueryRunOutcome: Sendable {
        var rc: Int32
        var errno: UInt32
        var message: String
        var sqlState: String
        var statementErrorCount: Int
        var sawConnectionLost: Bool
        var firstServerError: MySQLServerError?
        var needsReset: Bool
    }

    // MARK: 状态

    /// 专用串行队列：本连接上所有 libmysqlclient 调用都在这里。
    let queue: DispatchQueue

    private let stateLock = NSLock()
    private var conn: OpaquePointer?
    private var state = State()

    private struct State {
        var isOpen = false
        var needsReset = false
        var threadID: UInt64 = 0
    }

    init(label: String) {
        self.queue = DispatchQueue(label: label)
    }

    deinit {
        // 正常情况下由 close() 释放。若走到这里，说明没有排队的查询持有本对象，
        // 直接释放是安全的，避免泄漏。
        if let conn {
            mtl_conn_free(conn)
        }
    }

    // MARK: 跨队列状态读取

    var isOpen: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.isOpen
    }

    var needsReset: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.needsReset
    }

    var threadID: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.threadID
    }

    /// 标记连接已失效（连接断开 / ping 失败）。
    func markClosed() {
        stateLock.lock()
        state.isOpen = false
        state.needsReset = true
        stateLock.unlock()
    }

    /// 标记连接已不同步，下一次使用前需重建（C 层打断流式读取后）。
    func markNeedsReset() {
        stateLock.lock()
        state.needsReset = true
        stateLock.unlock()
    }

    /// 请求中止当前语句。经 C 层的 `mtl_conn_cancel`，明确允许跨队列调用。
    func requestCancel() {
        stateLock.lock(); defer { stateLock.unlock() }
        if let conn {
            mtl_conn_cancel(conn)
        }
    }

    private func currentHandle() -> OpaquePointer? {
        stateLock.lock(); defer { stateLock.unlock() }
        return conn
    }

    // MARK: 连接生命周期

    /// 建立连接。已存在的句柄会被 `mtl_conn_open` 内部的 close 逻辑替换。
    func open(_ parameters: OpenParameters) async throws -> Handshake {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let handshake = try openOnQueue(parameters)
                    continuation.resume(returning: handshake)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func openOnQueue(_ parameters: OpenParameters) throws -> Handshake {
        if conn == nil {
            guard let created = mtl_conn_create() else {
                throw MySQLError.internalError("mtl_conn_create 返回 NULL")
            }
            conn = created
        }
        guard let handle = conn else {
            throw MySQLError.internalError("连接句柄为空")
        }

        // 以下三项必须在 mtl_conn_open 之前设置
        mtl_conn_set_ssl(handle,
                         parameters.useSSL ? 1 : 0,
                         parameters.skipCertificateVerification ? 1 : 0)
        mtl_conn_set_connect_timeout(handle, UInt32(max(1, parameters.connectTimeout)))

        var err = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        let rc = mtl_conn_open(handle,
                               parameters.host,
                               UInt32(max(1, parameters.port)),
                               parameters.user,
                               parameters.password ?? "",
                               parameters.database,
                               parameters.charset,
                               nil,
                               &err,
                               err.count)
        guard rc == MTL_OK else {
            let message = cStringBuffer(err)
            stateLock.lock()
            state.isOpen = false
            state.needsReset = true
            state.threadID = 0
            stateLock.unlock()
            throw MySQLErrorMapper.connectFailure(step: .mysql,
                                                  message: message.isEmpty ? "连接失败" : message)
        }

        let version = cString(mtl_conn_server_version(handle))
        let hostInfo = cString(mtl_conn_server_info(handle))
        let thread = UInt64(mtl_conn_thread_id(handle))

        stateLock.lock()
        state.isOpen = true
        state.needsReset = false
        state.threadID = thread
        stateLock.unlock()

        return Handshake(serverVersion: version, hostInfo: hostInfo, threadID: thread)
    }

    /// 关闭并释放连接。所有排队中的查询会先执行完。
    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stateLock.lock()
                let handle = conn
                conn = nil
                state = State()
                stateLock.unlock()
                if let handle {
                    mtl_conn_free(handle)
                }
                continuation.resume()
            }
        }
    }

    /// 保活心跳。失败时标记连接失效并抛 `.connectionLost`。
    func ping() async throws {
        let outcome = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let handle = currentHandle(), mtl_conn_is_open(handle) == 1 else {
                    continuation.resume(returning: PingOutcome(rc: Int32(MTL_ERR_INVALID), errno: 0,
                                                              message: "连接不可用", sqlState: ""))
                    return
                }
                let rc = mtl_conn_ping(handle)
                guard rc != MTL_OK else {
                    continuation.resume(returning: PingOutcome(rc: rc, errno: 0, message: "", sqlState: ""))
                    return
                }
                let errno = mtl_conn_errno(handle)
                let message = cString(mtl_conn_error(handle))
                let sqlState = cString(mtl_conn_sqlstate(handle))
                stateLock.lock()
                state.isOpen = false
                state.needsReset = true
                stateLock.unlock()
                continuation.resume(returning: PingOutcome(rc: rc, errno: errno,
                                                          message: message, sqlState: sqlState))
            }
        }
        guard outcome.rc != MTL_OK else { return }
        let error = outcome.errno == 0
            ? nil
            : MySQLServerError(code: outcome.errno, sqlState: outcome.sqlState, message: outcome.message, sql: nil)
        throw MySQLError.connectionLost(error)
    }

    private struct PingOutcome: Sendable {
        var rc: Int32
        var errno: UInt32
        var message: String
        var sqlState: String
    }

    // MARK: 转义

    /// 转义字符串内容（不含首尾引号）。
    ///
    /// 内部 `queue.sync`：调用方**绝不能**在桥接队列上调用本方法（会死锁）。
    /// 见 `docs/tech-designs/03-mysql-layer.md` §4.2。
    func escape(_ text: String) -> String {
        queue.sync {
            let input = Array(text.utf8)
            guard let handle = currentHandle() else {
                return conservativeEscape(input)
            }
            if input.isEmpty { return "" }

            // mysql_real_escape_string 输出最多 2*len+1 字节（含结尾 NUL）
            var output = [CChar](repeating: 0, count: input.count * 2 + 2)
            let written = input.withUnsafeBufferPointer { inBuffer in
                output.withUnsafeMutableBufferPointer { outBuffer in
                    mtl_conn_escape(handle,
                                    inBuffer.baseAddress,
                                    input.count,
                                    outBuffer.baseAddress,
                                    outBuffer.count)
                }
            }
            guard written <= output.count else {
                return conservativeEscape(input)
            }
            return String(decoding: output.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    // MARK: 执行

    /// 在专用队列上执行一次查询。C 回调把事件直接 yield 进 `continuation`。
    func executeQuery(_ sql: String,
                      unbuffered: Bool,
                      continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation,
                      sqlPrefix: String) async -> QueryRunOutcome {
        await withCheckedContinuation { checked in
            queue.async { [self] in
                let outcome = runQueryOnQueue(sql,
                                              unbuffered: unbuffered,
                                              continuation: continuation,
                                              sqlPrefix: sqlPrefix)
                checked.resume(returning: outcome)
            }
        }
    }

    private func runQueryOnQueue(_ sql: String,
                                 unbuffered: Bool,
                                 continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation,
                                 sqlPrefix: String) -> QueryRunOutcome {
        guard let handle = currentHandle(), mtl_conn_is_open(handle) == 1 else {
            return QueryRunOutcome(rc: Int32(MTL_ERR_INVALID), errno: 0, message: "连接不可用",
                                   sqlState: "", statementErrorCount: 0, sawConnectionLost: false,
                                   firstServerError: nil, needsReset: true)
        }

        // C 层在 mtl_conn_query 开头也会清，这里按头文件要求再清一次
        mtl_conn_clear_cancel(handle)

        // sink 必须活到 mtl_conn_query 返回，因此在这里以强引用持有
        let sink = CallbackSink(continuation: continuation, sqlPrefix: sqlPrefix)
        var callbacks = MTLCallbacks(
            ctx: Unmanaged.passUnretained(sink).toOpaque(),
            on_result_set: mtlSessionOnResultSet,
            on_row: mtlSessionOnRow,
            on_statement_error: mtlSessionOnStatementError
        )

        var err = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        let rc = mtl_conn_query(handle,
                                sql,
                                sql.utf8.count,
                                unbuffered ? 1 : 0,
                                &callbacks,
                                &err,
                                err.count)

        let errno = mtl_conn_errno(handle)
        var message = cStringBuffer(err)
        if message.isEmpty { message = cString(mtl_conn_error(handle)) }
        let sqlState = cString(mtl_conn_sqlstate(handle))

        let needsReset = mtl_conn_needs_reset(handle) != 0 || sink.sawConnectionLost
        if needsReset {
            stateLock.lock()
            state.needsReset = true
            stateLock.unlock()
        }
        if sink.sawConnectionLost {
            stateLock.lock()
            state.isOpen = false
            stateLock.unlock()
        }

        return QueryRunOutcome(rc: rc,
                               errno: errno,
                               message: message,
                               sqlState: sqlState,
                               statementErrorCount: sink.statementErrorCount,
                               sawConnectionLost: sink.sawConnectionLost,
                               firstServerError: sink.firstServerError,
                               needsReset: needsReset)
    }
}

// MARK: - 列标志位（mysql_com.h）

/// `MYSQL_FIELD.flags` 的位定义。见 `docs/tech-designs/03-mysql-layer.md` §4.1。
enum MySQLColumnFlags {
    static let notNull: UInt32 = 1
    static let primaryKey: UInt32 = 2
    static let uniqueKey: UInt32 = 4
    static let multipleKey: UInt32 = 8
    static let blob: UInt32 = 16
    static let unsigned: UInt32 = 32
    static let zerofill: UInt32 = 64
    static let binary: UInt32 = 128
    static let enumFlag: UInt32 = 256
    static let autoIncrement: UInt32 = 512
    static let timestamp: UInt32 = 1024
    static let setFlag: UInt32 = 2048
    static let num: UInt32 = 32768
}

// MARK: - C 回调汇聚器

/// C 回调 `ctx` 的实际对象。
///
/// `@unchecked Sendable` 的理由：它正是 C 回调 `void *ctx` 背后那个对象，
/// 生命周期只覆盖一次 `mtl_conn_query`，且只会在 `CMySQLBridge.queue` 这条
/// 串行队列上被 libmysqlclient 同步访问；不存在真正的并发读写。
private final class CallbackSink: @unchecked Sendable {

    private let continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
    private let sqlPrefix: String

    private(set) var statementErrorCount = 0
    private(set) var sawConnectionLost = false
    private(set) var firstServerError: MySQLServerError?

    init(continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation, sqlPrefix: String) {
        self.continuation = continuation
        self.sqlPrefix = sqlPrefix
    }

    /// 结果集开始。列元数据里的字符串只在本次回调内有效，必须立刻复制。
    func beginResultSet(_ rs: MTLResultSet) {
        var columns: [ResultSetColumn] = []
        if let pointer = rs.columns, rs.column_count > 0 {
            columns.reserveCapacity(Int(rs.column_count))
            for index in 0..<Int(rs.column_count) {
                let column = pointer[index]
                let flags = column.flags
                columns.append(
                    ResultSetColumn(
                        name: cString(column.name),
                        originalTable: nilIfEmpty(cString(column.original_table)),
                        originalColumn: nilIfEmpty(cString(column.original_name)),
                        database: nilIfEmpty(cString(column.database)),
                        fieldType: column.type,
                        flags: flags,
                        charsetNumber: column.charset_nr,
                        length: column.length,
                        decimals: column.decimals,
                        kind: ResultSetColumn.classify(fieldType: column.type,
                                                       charsetNumber: column.charset_nr),
                        isBinary: column.charset_nr == MySQLFieldType.binaryCharsetNumber
                            || (flags & MySQLColumnFlags.binary) != 0,
                        isNotNull: (flags & MySQLColumnFlags.notNull) != 0,
                        isPrimaryKey: (flags & MySQLColumnFlags.primaryKey) != 0,
                        isUnsigned: (flags & MySQLColumnFlags.unsigned) != 0,
                        isAutoIncrement: (flags & MySQLColumnFlags.autoIncrement) != 0
                    )
                )
            }
        }

        let header = ResultSetHeader(index: Int(rs.result_index),
                                     columns: columns,
                                     affectedRows: rs.affected_rows > 0 ? UInt64(rs.affected_rows) : 0,
                                     lastInsertID: rs.last_insert_id)
        continuation.yield(.resultSet(header))
    }

    /// 一行数据。`mysql_fetch_row` 的缓冲区会被下一次调用复用，必须按 lengths 复制走，
    /// 禁止用 strlen。见 `AGENTS.md`「容易踩的坑」第 2 条、`docs/03` §2。
    func appendRow(_ row: MTLRow) {
        let count = Int(row.column_count)
        var values: [CellValue] = []
        values.reserveCapacity(count)

        if let rawValues = row.values {
            let lengths = row.lengths
            for index in 0..<count {
                guard let raw = rawValues[index] else {
                    values.append(.null)
                    continue
                }
                let length = lengths.map { Int($0[index]) } ?? 0
                let bytes = Array(UnsafeRawBufferPointer(start: raw, count: length))
                values.append(.bytes(bytes))
            }
        } else {
            values.append(contentsOf: Array(repeating: CellValue.null, count: count))
        }

        continuation.yield(.row(resultIndex: Int(row.result_index),
                                rowIndex: Int(row.row_index),
                                values: values))
    }

    /// 语句级错误。取消 / 超时码（1317 / 1927）不当作普通事件 yield，
    /// 由上层统一映射为 `.cancelled` / `.timeout`。
    func appendStatementError(resultIndex: Int32, code: UInt32, sqlState: String, message: String) {
        statementErrorCount += 1
        let error = MySQLServerError(code: code, sqlState: sqlState, message: message, sql: sqlPrefix)
        if firstServerError == nil { firstServerError = error }
        if error.isConnectionLost { sawConnectionLost = true }
        if MySQLErrorMapper.cancellation(fromServerCode: code) == nil {
            continuation.yield(.statementError(resultIndex: Int(resultIndex), error: error))
        }
    }
}

// MARK: - C 回调桥

private func mtlSessionOnResultSet(ctx: UnsafeMutableRawPointer?, rs: UnsafePointer<MTLResultSet>?) {
    guard let ctx, let rs else { return }
    Unmanaged<CallbackSink>.fromOpaque(ctx).takeUnretainedValue().beginResultSet(rs.pointee)
}

private func mtlSessionOnRow(ctx: UnsafeMutableRawPointer?, row: UnsafePointer<MTLRow>?) -> Int32 {
    guard let ctx, let row else { return 0 }
    Unmanaged<CallbackSink>.fromOpaque(ctx).takeUnretainedValue().appendRow(row.pointee)
    // 取消标志由 C 层轮询，这里始终返回 0
    return 0
}

private func mtlSessionOnStatementError(ctx: UnsafeMutableRawPointer?,
                                        resultIndex: Int32,
                                        code: UInt32,
                                        sqlstate: UnsafePointer<CChar>?,
                                        message: UnsafePointer<CChar>?) {
    guard let ctx else { return }
    Unmanaged<CallbackSink>.fromOpaque(ctx).takeUnretainedValue()
        .appendStatementError(resultIndex: resultIndex,
                              code: code,
                              sqlState: cString(sqlstate),
                              message: cString(message))
}

// MARK: - 工具

private func cString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}

private func cStringBuffer(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func nilIfEmpty(_ value: String) -> String? {
    value.isEmpty ? nil : value
}

/// 没有连接时的保守转义：`'` `"` `\` 加反斜杠，`\0` 写成 `\0`。
/// 与 `SQLValueLiteralizer.conservative` 语义一致。
private func conservativeEscape(_ input: [UInt8]) -> String {
    var output: [UInt8] = []
    output.reserveCapacity(input.count)
    for byte in input {
        switch byte {
        case 0x27, 0x22, 0x5C: // ' " \
            output.append(0x5C)
            output.append(byte)
        case 0x00:
            output.append(0x5C)
            output.append(0x30) // '0'
        default:
            output.append(byte)
        }
    }
    return String(decoding: output, as: UTF8.self)
}
