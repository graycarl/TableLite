import Foundation
import Dispatch
import Synchronization
import CMySQLClient

/// 对外唯一的数据库访问入口（actor）。
///
/// 硬约束（`docs/tech-designs/01-architecture.md` §3）：
/// - 内部持有专用串行队列（`MySQLConnectionHandle.queue`），并把它作为 actor executor，
///   对该连接的所有 libmysqlclient 调用都在该队列上执行；
/// - `cancel()` 是唯一允许跨队列的例外：只读缓存的 `thread_id`，经独立控制连接发 `KILL QUERY`；
/// - C 回调只复制数据，不回灌 UI。
///
/// 类型映射、错误映射与连接参数映射见 `docs/tech-designs/03-mysql-layer.md`。
public actor MySQLSession {

    /// 会话状态。
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case failed(MySQLError)
    }

    // MARK: 状态

    private let handle: MySQLConnectionHandle
    private let cancelTransport: MySQLCancelTransport
    /// 用于重连（`reconnect()` 用同一参数）。
    private var parameters: MySQLConnectionParameters?

    public private(set) var state: State = .disconnected
    /// 配置里的库不存在（`1049`）时，这里记录库名：连接本身成功，只是没选中它。
    ///
    /// 见 `docs/tech-designs/05-session-management.md` §3。
    public private(set) var unresolvedDatabase: String?
    /// 因 `mtl_conn_needs_reset` 而自动重建连接的次数（取消流式读取后会发生）。
    public private(set) var autoReconnectCount: Int = 0

    public init() {
        handle = MySQLConnectionHandle(label: "com.graycarl.tablelite.mysql.session")
        cancelTransport = MySQLCancelTransport()
    }

    /// 让所有 actor 方法都跑在 session 的专用串行队列上，直接满足 §3 的线程约束。
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        handle.queue.asUnownedSerialExecutor()
    }

    deinit {
        if let connection = handle.takeConnection() {
            mtl_conn_free(connection)
        }
        cancelTransport.close()
    }

    // MARK: 静态信息

    /// 链接到的 libmysqlclient 版本（不需要已建立的连接）。
    public static var clientLibraryVersion: String {
        mysqlCString(mtl_client_version())
    }

    // MARK: 状态查询

    public var needsReset: Bool {
        guard let connection = handle.pointer else { return true }
        return mtl_conn_needs_reset(connection) != 0
    }

    public var isConnected: Bool { handle.pointer != nil }

    /// 仍可重连时返回当前参数。
    public var currentParameters: MySQLConnectionParameters? { parameters }

    /// 服务器线程 id，用于诊断与 `KILL QUERY`。
    public var serverThreadID: UInt64 { handle.serverThreadIDValue }

    // MARK: 生命周期

    /// 建立连接。已连接时会先关闭旧连接。
    public func connect(_ parameters: MySQLConnectionParameters) async throws {
        state = .connecting
        do {
            try openConnection(parameters)
            self.parameters = parameters
            cancelTransport.update(parameters: parameters)
            state = .connected
        } catch let error as MySQLError {
            state = .failed(error)
            throw error
        } catch {
            let mapped = MySQLError(kind: .connectionFailed, code: 0, sqlState: "",
                                    message: String(describing: error))
            state = .failed(mapped)
            throw mapped
        }
    }

    /// 断开连接。保留参数，便于 `reconnect()`。
    public func disconnect() async {
        closeConnection()
        cancelTransport.update(parameters: nil)
        cancelTransport.close()
        unresolvedDatabase = nil
        state = .disconnected
    }

    /// 用当前参数重建连接（服务器断开 / 取消后需要时由上层调用）。
    public func reconnect() async throws {
        guard let parameters else {
            throw MySQLError(kind: .invalidInput, code: 0, sqlState: "",
                             message: "没有可用的连接参数，无法重连")
        }
        state = .connecting
        do {
            try openConnection(parameters)
            cancelTransport.update(parameters: parameters)
            state = .connected
        } catch let error as MySQLError {
            state = .failed(error)
            throw error
        }
    }

    /// 保活心跳。失败时标记会话失效并抛 `MySQLError`（`2006` / `2013` 可被上层识别）。
    public func ping() async throws {
        guard let connection = handle.pointer else {
            let error = MySQLError.notConnected()
            state = .failed(error)
            throw error
        }
        if mtl_conn_ping(connection) == MTL_OK {
            state = .connected
            return
        }
        let error = MySQLError(
            kind: .serverGone,
            code: mtl_conn_errno(connection),
            sqlState: mysqlCString(mtl_conn_sqlstate(connection)),
            message: mysqlCString(mtl_conn_error(connection)),
            statement: "ping"
        )
        state = .failed(error)
        throw error
    }

    // MARK: 转义（S29：Preview 与下发共用连接转义器）

    /// 用连接的转义器转义文本（不含首尾引号）。
    public nonisolated func escape(_ text: String) -> String {
        handle.escape(text)
    }

    /// `SQLValueLiteral` 需要的转义注入点。
    public nonisolated func makeEscaper() -> SQLValueLiteral.StringEscaper {
        let handle = self.handle
        return { text in handle.escape(text) }
    }

    /// 连接 charset 非 utf8 系时的字面量引入符（如 `_latin1`）。
    public nonisolated var charsetIntroducer: String? {
        SQLValueLiteral.charsetIntroducer(for: handle.charsetName)
    }

    /// 由已转义文本拼出字符串字面量。
    public nonisolated func stringLiteral(for text: String) -> String {
        SQLValueLiteral.quotedPreEscaped(escape(text), introducer: charsetIntroducer)
    }

    // MARK: 执行

    /// 执行一段 SQL（可含多条语句），缓冲全部行后返回。
    ///
    /// 语句级错误不抛异常，放在 `result.statementErrors` 里；只有连接层失败才抛 `MySQLError`。
    public func execute(_ sql: String, unbuffered: Bool = false) async throws -> MySQLQueryResult {
        let accumulator = MySQLQueryResultAccumulator()
        let summary = try await runQuery(sql, unbuffered: unbuffered) { event in
            accumulator.record(event)
        }
        return accumulator.makeResult(summary: summary)
    }

    /// 流式执行：逐结果集 / 逐行回调，不在 session 侧缓冲。
    ///
    /// 回调在 session 的串行队列上同步执行，只应做数据复制或计数，不得阻塞、不得回灌 UI。
    /// 因为要跨隔离域传给 actor，回调必须 `@Sendable`（`docs/tech-designs/01-architecture.md` §3、§4）。
    @discardableResult
    public func streamQuery(
        _ sql: String,
        unbuffered: Bool = false,
        onEvent: @escaping @Sendable (MySQLQueryEvent) -> Void
    ) async throws -> MySQLQuerySummary {
        try await runQuery(sql, unbuffered: unbuffered, onEvent: onEvent)
    }

    /// 事件流版本。背压按 L1 从宽：`AsyncThrowingStream` 使用无界缓冲。
    ///
    /// 超大结果集请优先用 `streamQuery` 的回调形式。
    public func queryEvents(_ sql: String, unbuffered: Bool = false) -> AsyncThrowingStream<MySQLQueryEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    _ = try await self.streamQuery(sql, unbuffered: unbuffered) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task.detached { [weak self] in
                    try? await self?.cancel()
                }
            }
        }
    }

    // MARK: 取消

    /// 取消当前查询：先置 C 侧取消标志，再从独立控制连接发 `KILL QUERY <thread_id>`。
    ///
    /// 只杀语句、不杀连接。控制连接不可用或 `KILL QUERY` 失败时抛 `MySQLError`，
    /// 由上层提示「取消失败，查询仍在服务器上运行」（`03-mysql-layer.md` §5）。
    public nonisolated func cancel() async throws {
        let handle = self.handle
        handle.requestCancel()
        let threadID = handle.serverThreadIDValue
        guard threadID != 0 else { return }
        try await cancelTransport.kill(threadID: threadID)
    }

    // MARK: 私有实现

    private func openConnection(_ parameters: MySQLConnectionParameters) throws {
        closeConnection()
        guard let raw = mtl_conn_create() else {
            throw MySQLError(kind: .connectionFailed, code: 0, sqlState: "",
                             message: "mysql_init 分配失败（内存不足）")
        }
        mtl_conn_set_ssl(raw, parameters.useSSL ? 1 : 0, parameters.skipCertificateVerification ? 1 : 0)
        mtl_conn_set_connect_timeout(raw, parameters.connectTimeoutSeconds)
        if parameters.readWriteTimeoutSeconds > 0 {
            mtl_conn_set_read_write_timeout(raw, parameters.readWriteTimeoutSeconds)
        }

        var errorBuffer = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        var attemptDatabase = parameters.database
        var missingDatabase: String?

        while true {
            let rc = mtl_conn_open(raw, parameters.host, parameters.port, parameters.user, parameters.password,
                                   attemptDatabase, parameters.charset, parameters.unixSocket,
                                   &errorBuffer, errorBuffer.count)
            if rc == MTL_OK { break }

            let code = mtl_conn_errno(raw)
            let sqlState = mysqlCString(mtl_conn_sqlstate(raw))
            let message = connectionErrorMessage(errorBuffer, connection: raw)

            // 1049：数据库不存在。连接本身是成功的，不带库重连即可（05 §3）。
            if !attemptDatabase.isEmpty, code == 1049 {
                missingDatabase = attemptDatabase
                attemptDatabase = ""
                continue
            }
            mtl_conn_free(raw)
            throw MySQLError.connectionFailure(code: code, sqlState: sqlState, message: message)
        }

        handle.install(raw)
        handle.setCharset(parameters.charset)
        handle.setServerThreadID(UInt64(mtl_conn_thread_id(raw)))
        handle.beginQuery()
        unresolvedDatabase = missingDatabase
    }

    private func closeConnection() {
        if let connection = handle.takeConnection() {
            mtl_conn_free(connection)
        }
        handle.setServerThreadID(0)
    }

    private func runQuery(
        _ sql: String,
        unbuffered: Bool,
        onEvent: @escaping (MySQLQueryEvent) -> Void
    ) async throws -> MySQLQuerySummary {
        guard let connection = handle.pointer else {
            throw MySQLError.notConnected(statement: sql)
        }
        let handle = self.handle
        handle.beginQuery()

        let context = MySQLQueryContext(statement: sql, onEvent: onEvent, isCancelled: { handle.isCancelled })
        var callbacks = MTLCallbacks(
            ctx: Unmanaged.passUnretained(context).toOpaque(),
            on_result_set: mysqlSessionOnResultSet,
            on_row: mysqlSessionOnRow,
            on_statement_error: mysqlSessionOnStatementError
        )
        var errorBuffer = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        let sqlBytes = Array(sql.utf8)

        let timeoutTask = scheduleTimeoutIfNeeded()
        defer { timeoutTask?.cancel() }

        let rc = sqlBytes.withUnsafeBufferPointer { buffer in
            mtl_conn_query(connection, buffer.baseAddress, sqlBytes.count, unbuffered ? 1 : 0,
                           &callbacks, &errorBuffer, errorBuffer.count)
        }

        let timedOut = handle.wasTimedOut
        var errors = context.statementErrors

        if errors.isEmpty, rc != MTL_OK {
            let message = connectionErrorMessage(errorBuffer, connection: connection)
            let error: MySQLError = rc == MTL_CANCELLED
                ? MySQLError.cancelled(timedOut: timedOut, statement: sql)
                : MySQLError.server(code: mtl_conn_errno(connection),
                                    sqlState: mysqlCString(mtl_conn_sqlstate(connection)),
                                    message: message,
                                    statement: sql)
            errors.append(MySQLStatementError(resultIndex: context.lastResultIndex, error: error))
        }

        if timedOut {
            // 客户端超时触发的中断，改标为 .timeout 以便 UI 区分。
            errors = errors.map { entry in
                guard entry.error.kind == .interrupted else { return entry }
                return MySQLStatementError(
                    resultIndex: entry.resultIndex,
                    error: MySQLError(kind: .timeout, code: entry.error.code, sqlState: entry.error.sqlState,
                                      message: entry.error.message, statement: entry.error.statement)
                )
            }
        }

        if rc == MTL_ERR_INVALID {
            let error = MySQLError.connectionFailure(
                code: mtl_conn_errno(connection),
                sqlState: mysqlCString(mtl_conn_sqlstate(connection)),
                message: connectionErrorMessage(errorBuffer, connection: connection)
            )
            state = .failed(error)
            throw error
        }

        // 取消流式读取后连接不同步：用同一参数自动重建（03 §5 / 01 §3.1）。
        if mtl_conn_needs_reset(connection) != 0, let parameters {
            do {
                try openConnection(parameters)
                cancelTransport.update(parameters: parameters)
                state = .connected
                autoReconnectCount += 1
            } catch let error as MySQLError {
                state = .failed(error)
                throw error
            }
        }

        return MySQLQuerySummary(
            resultSetCount: context.resultSetCount,
            rowCount: context.rowCount,
            affectedRows: context.affectedRows,
            lastInsertID: context.lastInsertID,
            statementErrors: errors,
            // 取消标志可能刚好与查询完成同时落地；只有真的产生了中断/超时错误才算「已取消」。
            wasCancelled: rc == MTL_CANCELLED || errors.contains { $0.error.isCancellation }
        )
    }

    /// 按 `queryTimeout` 起一个脱离 actor 的定时器：到点置取消标志并 KILL QUERY。
    ///
    /// 必须 `Task.detached`：若继承 actor 隔离，查询正阻塞 executor，定时器根本醒不过来。
    private func scheduleTimeoutIfNeeded() -> Task<Void, Never>? {
        guard let parameters, parameters.queryTimeout > 0 else { return nil }
        let timeoutSeconds = parameters.queryTimeout
        let handle = self.handle
        return Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            handle.markTimedOut()
            try? await self?.cancel()
        }
    }

    private func connectionErrorMessage(_ buffer: [CChar], connection: OpaquePointer) -> String {
        let text = bufferString(buffer)
        return text.isEmpty ? mysqlCString(mtl_conn_error(connection)) : text
    }
}

// MARK: - 查询上下文

/// 承载一次查询的回调上下文。只在 session 队列上同步使用，因此不需要同步原语。
private final class MySQLQueryContext {
    let statement: String?
    let onEvent: (MySQLQueryEvent) -> Void
    let isCancelled: () -> Bool

    private(set) var statementErrors: [MySQLStatementError] = []
    private(set) var resultSetCount = 0
    private(set) var rowCount = 0
    private(set) var affectedRows: Int64 = 0
    private(set) var lastInsertID: UInt64 = 0
    private(set) var lastResultIndex = 0

    init(statement: String?, onEvent: @escaping (MySQLQueryEvent) -> Void, isCancelled: @escaping () -> Bool) {
        self.statement = statement
        self.onEvent = onEvent
        self.isCancelled = isCancelled
    }

    func beginResultSet(_ header: MySQLResultSetHeader) {
        resultSetCount += 1
        lastResultIndex = header.index
        if !header.hasColumns {
            affectedRows += header.affectedRows
            if header.lastInsertID != 0 {
                lastInsertID = header.lastInsertID
            }
        }
        onEvent(.resultSet(header))
    }

    func appendRow(_ row: MySQLRow) {
        rowCount += 1
        lastResultIndex = row.resultIndex
        onEvent(.row(row))
    }

    func appendStatementError(_ error: MySQLError) {
        let entry = MySQLStatementError(resultIndex: lastResultIndex, error: error)
        statementErrors.append(entry)
        onEvent(.statementError(entry))
    }

    var shouldAbort: Bool { isCancelled() }
}

// MARK: - C 回调（只复制数据，禁止回灌 UI）

private func mysqlSessionOnResultSet(ctx: UnsafeMutableRawPointer?, rs: UnsafePointer<MTLResultSet>?) {
    guard let ctx, let rs else { return }
    Unmanaged<MySQLQueryContext>.fromOpaque(ctx).takeUnretainedValue()
        .beginResultSet(MySQLResultSetHeader(rs.pointee))
}

private func mysqlSessionOnRow(ctx: UnsafeMutableRawPointer?, row: UnsafePointer<MTLRow>?) -> Int32 {
    guard let ctx, let row else { return 0 }
    let context = Unmanaged<MySQLQueryContext>.fromOpaque(ctx).takeUnretainedValue()
    context.appendRow(MySQLRow(row.pointee))
    return context.shouldAbort ? 1 : 0
}

private func mysqlSessionOnStatementError(ctx: UnsafeMutableRawPointer?, resultIndex: Int32, code: UInt32,
                                          sqlstate: UnsafePointer<CChar>?, message: UnsafePointer<CChar>?) {
    guard let ctx else { return }
    let context = Unmanaged<MySQLQueryContext>.fromOpaque(ctx).takeUnretainedValue()
    context.appendStatementError(
        MySQLError.server(code: code,
                          sqlState: mysqlCString(sqlstate),
                          message: mysqlCString(message),
                          statement: context.statement)
    )
}

// MARK: - 缓冲结果收集

/// 只在 `execute()` 的 actor 上下文里使用，不跨并发域。
private final class MySQLQueryResultAccumulator {
    private var headers: [MySQLResultSetHeader] = []
    private var rowsByIndex: [Int: [MySQLRow]] = [:]

    func record(_ event: MySQLQueryEvent) {
        switch event {
        case .resultSet(let header):
            headers.append(header)
        case .row(let row):
            rowsByIndex[row.resultIndex, default: []].append(row)
        case .statementError:
            break // 汇总里已有 statementErrors
        }
    }

    func makeResult(summary: MySQLQuerySummary) -> MySQLQueryResult {
        let resultSets = headers.map { header in
            MySQLBufferedResultSet(header: header, rows: rowsByIndex[header.index] ?? [])
        }
        return MySQLQueryResult(
            resultSets: resultSets,
            statementErrors: summary.statementErrors,
            wasCancelled: summary.wasCancelled,
            rowCount: summary.rowCount,
            affectedRows: summary.affectedRows,
            lastInsertID: summary.lastInsertID
        )
    }
}

// MARK: - 工具

private func bufferString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
