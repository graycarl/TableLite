import Foundation
import Synchronization
@testable import TableLite

// MARK: - 可推进的时钟

/// 单测用：可手动推进的时间。
final class MutableClock: Clock {
    private let instant: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        instant = Mutex(start)
    }

    var now: Date { instant.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        instant.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

// MARK: - 假 MySQLSession

/// 可脚本化的 `MySQLSessionProtocol` 替身。
actor FakeMySQLSession: MySQLSessionProtocol {

    // MARK: 可配置

    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var reconnectCount = 0
    private(set) var pingCount = 0
    private(set) var executedSQL: [String] = []

    private var connectError: Error?
    private var pingError: Error?
    private var unresolvedDatabaseValue: String?
    private var stateValue: MySQLSession.State = .disconnected
    private var parameters: MySQLConnectionParameters?
    /// 按「子串命中顺序」返回结果。
    private var responses: [(String, MySQLQueryResult)] = []
    /// 按「子串命中顺序」抛错，优先于 `responses`。
    private var failures: [(String, Error)] = []
    private var defaultResult = MySQLQueryResult.empty

    func setConnectError(_ error: Error?) { connectError = error }
    func setPingError(_ error: Error?) { pingError = error }
    func setUnresolvedDatabase(_ value: String?) { unresolvedDatabaseValue = value }
    func setResponses(_ responses: [(String, MySQLQueryResult)]) { self.responses = responses }
    func setFailures(_ failures: [(String, Error)]) { self.failures = failures }
    func setState(_ state: MySQLSession.State) { stateValue = state }

    // MARK: 生命周期

    func connect(_ parameters: MySQLConnectionParameters) async throws {
        connectCount += 1
        self.parameters = parameters
        if let connectError {
            stateValue = .failed(MySQLError.notConnected())
            throw connectError
        }
        stateValue = .connected
    }

    func disconnect() async {
        disconnectCount += 1
        stateValue = .disconnected
    }

    func reconnect() async throws {
        reconnectCount += 1
        if let connectError {
            stateValue = .failed(MySQLError.notConnected())
            throw connectError
        }
        stateValue = .connected
    }

    func ping() async throws {
        pingCount += 1
        if let pingError {
            stateValue = .failed(pingError as? MySQLError ?? .notConnected())
            throw pingError
        }
        stateValue = .connected
    }

    // MARK: 执行

    func execute(_ sql: String, unbuffered: Bool) async throws -> MySQLQueryResult {
        executedSQL.append(sql)
        if let failure = failures.first(where: { sql.contains($0.0) }) {
            throw failure.1
        }
        if let match = responses.first(where: { sql.contains($0.0) }) {
            return match.1
        }
        return defaultResult
    }

    func streamQuery(
        _ sql: String,
        unbuffered: Bool,
        onEvent: @escaping @Sendable (MySQLQueryEvent) -> Void
    ) async throws -> MySQLQuerySummary {
        let result = try await execute(sql, unbuffered: unbuffered)
        for row in result.resultSets.first?.rows ?? [] {
            onEvent(.row(row))
        }
        return MySQLQuerySummary(
            resultSetCount: result.resultSets.count,
            rowCount: result.rowCount,
            affectedRows: result.affectedRows,
            lastInsertID: result.lastInsertID,
            statementErrors: result.statementErrors,
            wasCancelled: result.wasCancelled
        )
    }

    func cancel() async throws {}

    // MARK: 转义（nonisolated）

    nonisolated func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    nonisolated func makeEscaper() -> SQLValueLiteral.StringEscaper {
        { text in
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
        }
    }

    nonisolated var charsetIntroducer: String? { nil }

    // MARK: 状态

    var state: MySQLSession.State { stateValue }
    var unresolvedDatabase: String? { unresolvedDatabaseValue }
    var currentParameters: MySQLConnectionParameters? { parameters }
    var serverThreadID: UInt64 { 0 }
}

// MARK: - 假 SSH 隧道

actor FakeSSHTunnel: SSHTunnelProtocol {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var healthCheckCount = 0
    private(set) var stopAndWaitCount = 0

    private var startError: SSHTunnelError?
    private var localPort: UInt16
    private var stateValue: SSHTunnelState = .idle

    let configuration: SSHTunnelConfiguration

    init(configuration: SSHTunnelConfiguration, localPort: UInt16 = 53142) {
        self.configuration = configuration
        self.localPort = localPort
    }

    func setStartError(_ error: SSHTunnelError?) { startError = error }

    func start() async throws -> SSHTunnelEndpoint {
        startCount += 1
        if let startError {
            stateValue = .failed(startError)
            throw startError
        }
        stateValue = .established(localPort: localPort)
        return SSHTunnelEndpoint(port: localPort)
    }

    func stop() async {
        stopCount += 1
        stateValue = .closed
    }

    nonisolated func stopAndWait(timeout: Duration) {
        // 测试里不再等待。
    }

    func healthCheck() async -> Bool {
        healthCheckCount += 1
        return stateValue.localPort != nil
    }

    var state: SSHTunnelState { stateValue }
}

// MARK: - 结果集构造

extension MySQLQueryResult {
    static let empty = MySQLQueryResult(
        resultSets: [],
        statementErrors: [],
        wasCancelled: false,
        rowCount: 0,
        affectedRows: 0,
        lastInsertID: 0
    )

    /// 构造一个「语句级错误放在 result 里」的结果（`ConnectionSession.execute` 不抛异常）。
    static func statementError(_ error: MySQLError) -> MySQLQueryResult {
        MySQLQueryResult(
            resultSets: [],
            statementErrors: [MySQLStatementError(resultIndex: 0, error: error)],
            wasCancelled: false,
            rowCount: 0,
            affectedRows: 0,
            lastInsertID: 0
        )
    }

    /// 构造一个单结果集，便于元数据映射测试。
    static func single(columns: [String], rows: [[String?]]) -> MySQLQueryResult {
        let columnInfos = columns.map { ColumnInfo(name: $0, fieldType: .varString) }
        let mysqlRows = rows.enumerated().map { offset, row -> MySQLRow in
            let cells = row.map { text -> MySQLCell in
                guard let text else { return .null }
                return .bytes(Data(text.utf8))
            }
            return MySQLRow(resultIndex: 0, rowIndex: Int64(offset), cells: cells)
        }
        let header = MySQLResultSetHeader(index: 0, columns: columnInfos, affectedRows: 0, lastInsertID: 0)
        return MySQLQueryResult(
            resultSets: [MySQLBufferedResultSet(header: header, rows: mysqlRows)],
            statementErrors: [],
            wasCancelled: false,
            rowCount: rows.count,
            affectedRows: 0,
            lastInsertID: 0
        )
    }
}
