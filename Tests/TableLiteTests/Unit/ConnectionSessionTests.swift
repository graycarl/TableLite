import XCTest
@testable import TableLite

/// `ConnectionSession`：连接分步、错误区分、查询记录、DDL 刷新、标签保护。
@MainActor
final class ConnectionSessionTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    // MARK: 连接流程

    func testSuccessfulConnectExposesDatabasesAndServerInfo() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.serverInfo?.version, "8.0.36")
        XCTAssertEqual(session.databases, ["app_dev"])
        XCTAssertEqual(session.unfilteredDatabases, ["app_dev", "mysql"])
        XCTAssertEqual(session.selectedDatabase, "app_dev")
        XCTAssertNil(session.warning)

        let steps = await harness.mysql.connectCount
        XCTAssertEqual(steps, 1)
    }

    func testSSHFailureIsReportedOnSSHStep() async throws {
        let connection = SessionTestSupport.connection(ssh: true)
        await harness.tunnel.setStartError(.authenticationFailed(stderrTail: "Permission denied (publickey)."))

        do {
            _ = try await harness.manager.connect(connection, password: nil)
            XCTFail("应当抛出 ConnectFailure")
        } catch let failure as ConnectFailure {
            XCTAssertEqual(failure.step, .sshTunnel)
            XCTAssertEqual(failure.sshError, .authenticationFailed(stderrTail: "Permission denied (publickey)."))
            XCTAssertTrue(failure.underlyingMessage.contains("Permission denied"))
            // MySQL 根本没被尝试。
            let connectCount = await harness.mysql.connectCount
            XCTAssertEqual(connectCount, 0)
        }
    }

    func testMySQLFailureIsReportedOnMySQLStep() async throws {
        let connection = SessionTestSupport.connection()
        await harness.mysql.setConnectError(MySQLError.server(code: 1045, sqlState: "28000", message: "Access denied"))

        do {
            _ = try await harness.manager.connect(connection, password: nil)
            XCTFail("应当抛出 ConnectFailure")
        } catch let failure as ConnectFailure {
            XCTAssertEqual(failure.step, .mysql)
            XCTAssertEqual(failure.mysqlError?.code, 1045)
            XCTAssertEqual(failure.mysqlError?.kind, .authentication)
        }
    }

    func testUnresolvedDatabaseIsWarningNotFailure() async throws {
        let connection = SessionTestSupport.connection(database: "missing_db")
        await harness.mysql.setUnresolvedDatabase("missing_db")

        let session = try await harness.manager.connect(connection, password: nil)
        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.unresolvedDatabase, "missing_db")
        XCTAssertTrue(session.warning?.contains("missing_db") ?? false)
    }

    // MARK: 查询记录

    func testExecuteRecordsHistoryAndConsoleLog() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)

        _ = try await session.execute("SELECT 1")

        let historyCount = try await harness.history.count(connectionID: connection.id)
        XCTAssertEqual(historyCount, 1)
        XCTAssertTrue(harness.consoleLog.allEntries.contains { $0.sql == "SELECT 1" && $0.tag == .data })
    }

    func testExecuteWithRecordHistoryFalseSkipsHistory() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)

        _ = try await session.execute("SELECT 2", recordHistory: false)
        let historyCount = try await harness.history.count(connectionID: connection.id)
        XCTAssertEqual(historyCount, 0)
    }

    // MARK: DDL

    func testDDLInvalidatesMetaAndMarksStructureTabStale() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)
        let structureTab = session.openTableStructure(database: "app_dev", table: "users")
        XCTAssertFalse(structureTab.isStale)

        let before = await harness.mysql.executedSQL.filter { $0.contains("TABLE_COLLATION") }.count
        _ = try await session.execute("DROP TABLE app_dev.users")
        let after = await harness.mysql.executedSQL.filter { $0.contains("TABLE_COLLATION") }.count

        XCTAssertTrue(structureTab.isStale)
        XCTAssertGreaterThan(after, before, "DDL 后应重新拉取对象树")
    }

    // MARK: 标签 / 重连

    func testReconnectKeepsTabsAndPendingChanges() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)
        let tab = session.openTableData(database: "app_dev", table: "users")
        tab.hasPendingChanges = true

        try await harness.manager.reconnect(id: connection.id)

        XCTAssertEqual(session.state, .connected)
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertTrue(session.tabs[0].hasPendingChanges)
        XCTAssertEqual(session.tabs[0].id, tab.id)
    }

    func testTableDataTabRestoresColumnLayout() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)
        session.saveTableLayout(
            database: "app_dev",
            table: "users",
            layout: TableLayout(columnWidths: ["id": 120], hiddenColumns: ["payload"])
        )

        let tab = session.openTableData(database: "app_dev", table: "users")
        XCTAssertEqual(tab.hiddenColumns, ["payload"])
        XCTAssertEqual(session.tableLayout(database: "app_dev", table: "users")?.columnWidths["id"], 120)
    }

    func testIdleRequiresNoTabs() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)
        harness.clock.advance(by: 6 * 60)
        XCTAssertTrue(session.isIdle(threshold: SessionManager.idleThreshold))

        session.openTableData(database: "app_dev", table: "users")
        XCTAssertFalse(session.isIdle(threshold: SessionManager.idleThreshold))
    }
}
