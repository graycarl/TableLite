import Foundation
import os
import Synchronization
import CMySQLClient

// MARK: - 事件

/// `MySQLSession` 主动上报给上层的事件。`SessionManager` 通过 `setEventHandler` 订阅。
enum MySQLSessionEvent: Sendable {
    /// 心跳失败 / 服务器返回 2006 / 2013。上层据此把状态栏变红并提供「重新连接」。
    case connectionLost(MySQLServerError?)
}

// MARK: - MySQLSession

/// 数据库访问层的唯一入口（actor）。
///
/// 并发模型见 `docs/tech-designs/01-architecture.md` §3：
/// - 每个 session 持有一条专用串行队列（封装在 `CMySQLBridge` 内），
///   对该连接的所有 libmysqlclient 调用都在其上执行；
/// - 唯一允许跨队列的是 `KILL QUERY`（经独立控制连接）与 `mtl_conn_cancel`；
/// - C 回调只复制数据、不回灌 UI。
///
/// 取消与超时见 `docs/tech-designs/03-mysql-layer.md` §5：
/// 用户取消 / 超时统一走 `KILL QUERY <thread_id>`，只杀语句不杀连接；
/// 本地 `cancelRequested` + C 层 cancel 让取行循环尽快返回；
/// 流式读取被打断后 `needs_reset=1`，下一次使用前重建该连接。
actor MySQLSession {

    struct Configuration: Sendable {
        var mysql: MySQLConnectConfig
        var password: String?
        /// 实际连接端点（SSH 隧道时是 127.0.0.1）
        var host: String
        var port: Int
    }

    // MARK: 状态

    private let configuration: Configuration
    private let clock: Clock
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "mysql.session")

    private var bridge: CMySQLBridge?
    private var killControl: KillControlConnection?
    private var serverInfoStorage: ServerInfo?
    private var eventHandler: (@Sendable (MySQLSessionEvent) -> Void)?

    /// 连接已失效（心跳失败 / 2006 / 2013）。此时 `ensureConnected` 不会自动重建，
    /// 必须由上层显式 `open()`。
    private var disconnected = false
    /// 本地取消标志（与 C 层 cancel 配合）。
    private var cancelRequested = false
    /// 当前正在跑的查询尝试。取消时据此决定是否发 KILL。
    private var activeAttempt: QueryAttempt?

    init(configuration: Configuration, clock: Clock) {
        self.configuration = configuration
        self.clock = clock
    }

    // MARK: 只读属性

    var isOpen: Bool { bridge?.isOpen == true && !disconnected }

    var serverInfo: ServerInfo? { serverInfoStorage }

    var serverVersion: String { serverInfoStorage?.version ?? "" }

    // MARK: 生命周期

    /// 连接并读取服务器信息（版本 / 字符集 / 排序规则 / sql_mode 一次查询取全）。
    func open() async throws {
        await close()

        let bridge = CMySQLBridge(label: "tablelite.mysql.\(UUID().uuidString)")
        self.bridge = bridge

        let handshake: CMySQLBridge.Handshake
        do {
            handshake = try await bridge.open(openParameters())
        } catch {
            logger.error("MySQL 连接失败：\(String(describing: error), privacy: .public)")
            self.bridge = nil
            throw error
        }

        killControl = KillControlConnection(parameters: openParameters())

        do {
            try await loadServerInfo(handshake)
        } catch {
            logger.error("读取服务器信息失败：\(String(describing: error), privacy: .public)")
            throw MySQLErrorMapper.connectFailure(step: .serverInfo,
                                                  message: "读取服务器信息失败",
                                                  detail: String(describing: error))
        }
    }

    func close() async {
        // 先取消正在跑的查询，避免 close 卡在桥接队列上
        await cancelCurrentQuery()

        cancelRequested = false
        activeAttempt = nil

        let bridge = self.bridge
        let killControl = self.killControl
        self.bridge = nil
        self.killControl = nil
        self.serverInfoStorage = nil
        self.disconnected = false

        await killControl?.close()
        await bridge?.close()
    }

    /// 保活心跳。失败标记断开并通知上层。
    func ping() async throws {
        guard !disconnected, let bridge = await ensureConnected() else {
            throw MySQLError.notConnected
        }
        do {
            try await bridge.ping()
        } catch {
            logger.error("MySQL ping 失败：\(String(describing: error), privacy: .public)")
            handleConnectionLost((error as? MySQLError)?.serverError)
            throw error
        }
    }

    func setEventHandler(_ handler: @escaping @Sendable (MySQLSessionEvent) -> Void) {
        eventHandler = handler
    }

    // MARK: 字面量转义

    /// 提供 `SQLValueLiteral` 需要的转义闭包。
    ///
    /// ⚠️ 该闭包内部 `queue.sync`，**查询执行期间不要生成字面量**（会阻塞在桥接队列之后）；
    /// 也绝不能从桥接队列上调用（会死锁）。见 `docs/tech-designs/03-mysql-layer.md` §4.2。
    func literalizer() -> SQLValueLiteralizer {
        let charset = configuration.mysql.charset
        guard let bridge else {
            var conservative = SQLValueLiteralizer.conservative
            conservative.charsetName = charset
            return conservative
        }
        return SQLValueLiteralizer(charsetName: charset, escape: { text in
            bridge.escape(text)
        })
    }

    // MARK: 查询

    /// 逐事件产出的查询。
    ///
    /// - `unbuffered == true`：`mysql_use_result`，逐行流式，适合导出 / 大结果；
    /// - `unbuffered == false`：`mysql_store_result`，适合分页。
    ///
    /// 取消消费者 Task 或调用 `cancelCurrentQuery()` 都会中断，流以 `.cancelled` 结束。
    func query(_ sql: String, unbuffered: Bool) -> AsyncThrowingStream<QueryEvent, Error> {
        let attempt = QueryAttempt()
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { [self] continuation in
            continuation.onTermination = { @Sendable reason in
                guard case .cancelled = reason else { return }
                attempt.markCancelled()
                Task {
                    await self.cancelCurrentQuery()
                }
            }
            Task {
                await self.produceQueryEvents(attempt: attempt,
                                              sql: sql,
                                              unbuffered: unbuffered,
                                              continuation: continuation)
            }
        }
    }

    /// 读全的结果集（元数据、分页查询用）。语句错误直接抛出。
    func queryAll(_ sql: String, unbuffered: Bool) async throws -> [MaterializedResultSet] {
        var results: [MaterializedResultSet] = []
        var pendingHeader: ResultSetHeader?
        var pendingRows: [[CellValue]] = []

        for try await event in query(sql, unbuffered: unbuffered) {
            switch event {
            case .resultSet(let header):
                if let pendingHeader {
                    results.append(MaterializedResultSet(header: pendingHeader, rows: pendingRows))
                }
                pendingHeader = header
                pendingRows = []

            case .row(_, _, let values):
                // C shim 正常不会出现列数与值数不一致；出现即按内部错误处理
                if let pendingHeader, pendingHeader.columns.count != values.count {
                    throw MySQLError.internalError("结果集列数与行值数量不一致")
                }
                pendingRows.append(values)

            case .statementError(_, let error):
                if error.isConnectionLost {
                    handleConnectionLost(error)
                    throw MySQLError.connectionLost(error)
                }
                if let cancellation = MySQLErrorMapper.cancellation(fromServerCode: error.code) {
                    throw cancellation
                }
                throw MySQLError.server(error)

            case .finished:
                break
            }
        }

        if let pendingHeader {
            results.append(MaterializedResultSet(header: pendingHeader, rows: pendingRows))
        }
        return results
    }

    /// 只需要影响行数时用（DML）。
    @discardableResult
    func execute(_ sql: String) async throws -> ResultSetHeader {
        let results = try await queryAll(sql, unbuffered: false)
        guard let header = results.first?.header else {
            throw MySQLError.internalError("执行语句后没有返回结果头")
        }
        return header
    }

    // MARK: 取消

    /// 取消当前语句。只杀语句、不杀连接：本地置 C 层取消标志，并经控制连接发 `KILL QUERY`。
    func cancelCurrentQuery() async {
        cancelRequested = true
        guard let bridge else { return }

        // 让取行循环尽快返回（可从任意线程调用）
        bridge.requestCancel()

        // 没有正在跑的查询时不发 KILL，避免误伤后续语句
        guard activeAttempt != nil else { return }

        let threadID = bridge.threadID
        guard threadID > 0, let killControl else { return }
        do {
            try await killControl.killQuery(threadID: threadID)
        } catch {
            // 控制连接不可用 / 权限不足：不动原连接，明确记录
            logger.error("KILL QUERY \(threadID) 失败：\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 查询生产者

    private func produceQueryEvents(attempt: QueryAttempt,
                                    sql: String,
                                    unbuffered: Bool,
                                    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation) async {
        activeAttempt = attempt
        defer {
            if activeAttempt === attempt { activeAttempt = nil }
            cancelRequested = false
        }

        let prefix = MySQLErrorMapper.sqlPrefix(sql)

        // 超时定时器：见 docs/tech-designs/03-mysql-layer.md §5
        let timeoutSeconds = configuration.mysql.queryTimeout
        var timeoutTask: Task<Void, Never>?
        if timeoutSeconds > 0 {
            let clock = self.clock
            timeoutTask = Task { [weak self] in
                // 被取消（查询已结束）时 `try?` 直接返回，不计入错误日志
                try? await clock.sleep(seconds: TimeInterval(timeoutSeconds))
                guard !Task.isCancelled else { return }
                attempt.markTimedOut()
                await self?.cancelCurrentQuery()
            }
        }
        defer { timeoutTask?.cancel() }

        guard !attempt.isCancelled else {
            continuation.finish(throwing: MySQLError.cancelled)
            return
        }
        guard let bridge = await ensureConnected() else {
            continuation.finish(throwing: MySQLError.notConnected)
            return
        }
        guard !attempt.isCancelled else {
            continuation.finish(throwing: MySQLError.cancelled)
            return
        }

        let outcome = await bridge.executeQuery(sql,
                                                unbuffered: unbuffered,
                                                continuation: continuation,
                                                sqlPrefix: prefix)

        if outcome.needsReset { bridge.markNeedsReset() }

        // 1) 取消 / 超时。服务器可能用 1317 / 1927 表达中断。
        if outcome.rc == Int32(MTL_CANCELLED) {
            continuation.finish(throwing: attempt.timedOut ? MySQLError.timeout : MySQLError.cancelled)
            return
        }
        if let cancellation = MySQLErrorMapper.cancellation(fromServerCode: outcome.errno) {
            continuation.finish(throwing: cancellation)
            return
        }
        if let serverError = outcome.firstServerError,
           let cancellation = MySQLErrorMapper.cancellation(fromServerCode: serverError.code) {
            continuation.finish(throwing: cancellation)
            return
        }

        // 2) 连接失效（2006 / 2013 或句柄已不可用）
        if outcome.sawConnectionLost || outcome.rc == Int32(MTL_ERR_INVALID) {
            let serverError = outcome.firstServerError
                ?? (outcome.errno != 0
                    ? MySQLServerError(code: outcome.errno, sqlState: outcome.sqlState,
                                       message: outcome.message, sql: prefix)
                    : nil)
            handleConnectionLost(serverError)
            continuation.finish(throwing: MySQLError.connectionLost(serverError))
            return
        }

        // 3) mysql_real_query 失败：C shim 不会回调 on_statement_error，这里补一条事件
        if outcome.rc == Int32(MTL_ERR_SQL) && outcome.statementErrorCount == 0 {
            continuation.yield(.statementError(
                resultIndex: 0,
                error: MySQLErrorMapper.serverError(code: outcome.errno,
                                                    sqlState: outcome.sqlState,
                                                    message: outcome.message,
                                                    sql: prefix)
            ))
        }

        // 4) 本地取消标志：用户在查询窗口内取消，但 C 层未能表现为中断，
        //    按取消语义收尾（本地 cancelRequested + C 层 cancel 的兜底）。
        if (cancelRequested || attempt.isCancelled)
            && outcome.rc == Int32(MTL_OK)
            && outcome.statementErrorCount == 0 {
            continuation.finish(throwing: MySQLError.cancelled)
            return
        }

        continuation.yield(.finished)
        continuation.finish()
    }

    // MARK: 连接维护

    /// 确保连接可用。`needsReset`（取消后不同步）会重建；`disconnected` 不自动重建。
    private func ensureConnected() async -> CMySQLBridge? {
        guard !disconnected, let bridge else { return nil }
        if bridge.isOpen && !bridge.needsReset { return bridge }

        do {
            _ = try await bridge.open(openParameters())
            logger.info("MySQL 连接已重建（needsReset）")
            return bridge
        } catch {
            logger.error("MySQL 连接重建失败：\(String(describing: error), privacy: .public)")
            bridge.markClosed()
            handleConnectionLost((error as? MySQLError)?.serverError)
            return nil
        }
    }

    private func handleConnectionLost(_ error: MySQLServerError?) {
        guard !disconnected else { return }
        disconnected = true
        bridge?.markClosed()
        logger.error("MySQL 连接失效：\(error?.formatted ?? "未知原因", privacy: .public)")
        eventHandler?(.connectionLost(error))
    }

    private func loadServerInfo(_ handshake: CMySQLBridge.Handshake) async throws {
        let sql = "SELECT VERSION() AS `version`, "
            + "@@character_set_client AS `charset`, "
            + "@@collation_connection AS `collation`, "
            + "@@sql_mode AS `sql_mode`"
        let results = try await queryAll(sql, unbuffered: false)
        if let row = results.first?.rows.first, row.count >= 4 {
            serverInfoStorage = ServerInfo(
                version: row[0].displayText.isEmpty ? handshake.serverVersion : row[0].displayText,
                hostInfo: handshake.hostInfo,
                charset: row[1].displayText,
                collation: row[2].displayText,
                sqlMode: row[3].displayText
            )
        } else {
            serverInfoStorage = ServerInfo(version: handshake.serverVersion,
                                           hostInfo: handshake.hostInfo,
                                           charset: configuration.mysql.charset,
                                           collation: "",
                                           sqlMode: "")
        }
    }

    private func openParameters() -> CMySQLBridge.OpenParameters {
        CMySQLBridge.OpenParameters(
            host: configuration.host,
            port: configuration.port,
            user: configuration.mysql.user,
            password: configuration.password,
            database: configuration.mysql.database,
            charset: configuration.mysql.charset,
            useSSL: configuration.mysql.useSSL,
            skipCertificateVerification: configuration.mysql.skipCertificateVerification,
            connectTimeout: configuration.mysql.connectTimeout
        )
    }
}

// MARK: - 查询尝试标志

/// 一次查询的取消 / 超时标志，跨 producer Task、流终止回调与超时 Task 共享。
/// 用 `Mutex` 保证线程安全，因此是正常的 `Sendable`（无需 `@unchecked`）。
private final class QueryAttempt: Sendable {
    private struct Flags: Sendable {
        var cancelled = false
        var timedOut = false
    }

    private let state = Mutex(Flags())

    var isCancelled: Bool { state.withLock { $0.cancelled } }
    var timedOut: Bool { state.withLock { $0.timedOut } }

    func markCancelled() { state.withLock { $0.cancelled = true } }
    func markTimedOut() { state.withLock { $0.timedOut = true } }
}

// MARK: - KILL QUERY 控制连接

/// `KILL QUERY <thread_id>` 的独立控制连接：懒创建、空闲 60s 自动关闭。
///
/// 只从「另一条连接」发送 KILL，绝不触碰主连接句柄（`docs/01` §3 第 3 条）。
///
/// `@unchecked Sendable` 的唯一理由：包装独立的 `MTLConn *`（C 指针）；
/// 所有访问都在自己的串行队列上，跨队列只读取一个不可变参数。
private final class KillControlConnection: @unchecked Sendable {

    private static let idleTimeout: TimeInterval = 60

    private let queue: DispatchQueue
    private let parameters: CMySQLBridge.OpenParameters
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "mysql.kill")

    /// 只在 `queue` 上访问
    private var conn: OpaquePointer?
    private var idleTimer: DispatchSourceTimer?

    init(parameters: CMySQLBridge.OpenParameters) {
        self.parameters = parameters
        self.queue = DispatchQueue(label: "tablelite.mysql.kill.\(UUID().uuidString)")
    }

    deinit {
        idleTimer?.cancel()
        if let conn {
            mtl_conn_free(conn)
        }
    }

    func killQuery(threadID: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try killOnQueue(threadID: threadID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closeOnQueue()
                continuation.resume()
            }
        }
    }

    private func killOnQueue(threadID: UInt64) throws {
        if conn == nil {
            try openOnQueue()
        }
        guard let handle = conn else {
            throw MySQLErrorMapper.connectFailure(step: .mysql, message: "控制连接不可用")
        }

        let sql = "KILL QUERY \(threadID)"
        var err = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        let rc = mtl_conn_query(handle, sql, sql.utf8.count, 0, nil, &err, err.count)
        guard rc == MTL_OK else {
            let message = cStringBuffer(err)
            // 控制连接可能已失效：关掉下次重建；主连接不受影响
            closeOnQueue()
            throw MySQLErrorMapper.connectFailure(step: .mysql,
                                                  message: message.isEmpty ? "KILL QUERY 失败" : message)
        }
        scheduleIdleClose()
    }

    private func openOnQueue() throws {
        guard let created = mtl_conn_create() else {
            throw MySQLError.internalError("控制连接 mtl_conn_create 返回 NULL")
        }
        mtl_conn_set_ssl(created,
                         parameters.useSSL ? 1 : 0,
                         parameters.skipCertificateVerification ? 1 : 0)
        mtl_conn_set_connect_timeout(created, UInt32(max(1, parameters.connectTimeout)))

        var err = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        let rc = mtl_conn_open(created,
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
            mtl_conn_free(created)
            throw MySQLErrorMapper.connectFailure(step: .mysql,
                                                  message: message.isEmpty ? "控制连接建立失败" : message)
        }
        conn = created
    }

    private func scheduleIdleClose() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleTimeout)
        timer.setEventHandler { [weak self] in
            self?.closeOnQueue()
        }
        timer.resume()
        idleTimer = timer
    }

    private func closeOnQueue() {
        idleTimer?.cancel()
        idleTimer = nil
        if let conn {
            mtl_conn_free(conn)
            self.conn = nil
        }
    }
}

// MARK: - 工具

private func cString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}

private func cStringBuffer(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
