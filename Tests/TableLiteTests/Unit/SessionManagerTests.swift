import XCTest
@testable import TableLite

/// `SessionManager`：连接上限、空闲回收、测试连接无痕、会话恢复、退出清理。
@MainActor
final class SessionManagerTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    // MARK: 连接上限

    func testConnectionLimitRejectsExtraSession() async throws {
        harness.preferences.maxSessions = 1
        let first = SessionTestSupport.connection(name: "A")
        let second = SessionTestSupport.connection(name: "B")

        _ = try await harness.manager.connect(first, password: nil)
        do {
            _ = try await harness.manager.connect(second, password: nil)
            XCTFail("应当抛出连接上限错误")
        } catch let error as SessionManagerError {
            XCTAssertEqual(error, .connectionLimitReached(limit: 1))
        }
        XCTAssertEqual(harness.manager.sessions.count, 1)
    }

    func testReconnectingExistingSessionDoesNotOpenNewConnection() async throws {
        let connection = SessionTestSupport.connection()
        let first = try await harness.manager.connect(connection, password: nil)
        let second = try await harness.manager.connect(connection, password: nil)

        XCTAssertTrue(first === second)
        XCTAssertEqual(harness.manager.sessions.count, 1)
        let connectCount = await harness.mysql.connectCount
        XCTAssertEqual(connectCount, 1)
    }

    // MARK: 空闲回收

    func testIdleReaperOnlyRecyclesTablessConnections() async throws {
        let idle = SessionTestSupport.connection(name: "idle")
        let busy = SessionTestSupport.connection(name: "busy")
        let idleSession = try await harness.manager.connect(idle, password: nil)
        let busySession = try await harness.manager.connect(busy, password: nil)
        busySession.openTableData(database: "app_dev", table: "users")

        harness.clock.advance(by: SessionManager.idleThreshold + 1)
        await harness.manager.reapIdleSessions()

        XCTAssertEqual(idleSession.state, .recycled)
        XCTAssertEqual(busySession.state, .connected)
        // 回收只断开、不删除会话对象。
        XCTAssertEqual(harness.manager.sessions.count, 2)
    }

    func testIdleReaperHonoursPreferenceOff() async throws {
        harness.preferences.idleDisconnect = false
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)

        harness.clock.advance(by: SessionManager.idleThreshold + 1)
        await harness.manager.reapIdleSessions()
        XCTAssertEqual(session.state, .connected)
    }

    // MARK: 测试连接

    func testTestConnectionDoesNotPersistOrRecordHistory() async throws {
        let connection = SessionTestSupport.connection()
        let report = await harness.manager.testConnection(connection, password: nil)

        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.serverInfo?.version, "8.0.36")
        XCTAssertTrue(harness.manager.sessions.isEmpty)

        let historyCount = try await harness.history.count(connectionID: connection.id)
        XCTAssertEqual(historyCount, 0)
        XCTAssertTrue(harness.consoleLog.allEntries.isEmpty)
    }

    func testTestConnectionReportsFailureStep() async throws {
        let connection = SessionTestSupport.connection()
        await harness.mysql.setConnectError(MySQLError.server(code: 1045, sqlState: "28000", message: "Access denied"))

        let report = await harness.manager.testConnection(connection, password: nil)
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.failure?.step, .mysql)
        XCTAssertEqual(report.steps.first(where: { $0.step == .mysql })?.failure?.step, .mysql)
        XCTAssertEqual(report.steps.first(where: { $0.step == .sshTunnel })?.outcome, .skipped)
    }

    // MARK: 保活

    func testPingFailureMarksSessionFailed() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)
        await harness.mysql.setPingError(MySQLError.server(code: 2006, sqlState: "HY000", message: "server gone away"))

        await harness.manager.pingActiveSessions()

        XCTAssertEqual(session.state.failure?.mysqlError?.code, 2006)
        XCTAssertEqual(session.state.failure?.step, .mysql)
    }

    // MARK: 会话恢复

    func testSessionRestoreRoundTripDoesNotAutoConnect() async throws {
        let connection = SessionTestSupport.connection()
        try await harness.connections.upsert(connection)

        let first = try await harness.manager.connect(connection, password: nil)
        first.openTableData(database: "app_dev", table: "users")
        let queryTab = first.newQueryTab(initialSQL: "SELECT 1")
        first.selectedDatabase = "app_dev"
        await harness.manager.persistSessionState()

        // 用同一个存储目录重开一个 manager。
        let second = SessionTestSupport.makeHarness(layout: harness.layout)
        await second.manager.restoreIfNeeded()

        XCTAssertEqual(second.manager.sessions.count, 1)
        let restored = second.manager.sessions[0]
        XCTAssertEqual(restored.state, .disconnected, "恢复后不自动连接")
        XCTAssertEqual(restored.selectedDatabase, "app_dev")
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.tabs[0].kind, .tableData(database: "app_dev", table: "users"))
        XCTAssertEqual(restored.tabs[1].kind.draftID, queryTab.kind.draftID)

        // 恢复全部后逐个连接。
        await second.manager.reconnectAll()
        XCTAssertEqual(second.manager.sessions[0].state, .connected)
    }

    func testRestoreSkippedWhenPreferenceOff() async throws {
        harness.preferences.restoreLastWorkspace = false
        let connection = SessionTestSupport.connection()
        try await harness.connections.upsert(connection)
        _ = try await harness.manager.connect(connection, password: nil)
        // 偏好关闭时不写 session.json。
        let loaded = try await harness.sessionState.load()
        XCTAssertNil(loaded)
    }

    // MARK: 退出清理

    func testPrepareForTerminationClosesSessions() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)

        await harness.manager.prepareForTermination()

        XCTAssertEqual(session.state, .disconnected)
        let disconnectCount = await harness.mysql.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
    }

    func testRemoveSessionDeletesQueryDrafts() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)
        let queryTab = session.newQueryTab(initialSQL: "SELECT 1")
        let draftID = try XCTUnwrap(queryTab.kind.draftID)
        try await harness.drafts.write("SELECT 1", id: draftID)

        await harness.manager.removeSession(id: connection.id)

        XCTAssertTrue(harness.manager.sessions.isEmpty)
        let content = try await harness.drafts.read(id: draftID)
        XCTAssertNil(content)
    }
}
