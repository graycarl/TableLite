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

    func testSSHSuccessExposesTunnelEndpoint() async throws {
        let connection = SessionTestSupport.connection(ssh: true)
        let session = try await harness.manager.connect(connection, password: nil)
        XCTAssertEqual(session.tunnelEndpoint, SSHTunnelEndpoint(port: 53142))
    }

    func testSSHConnectionFailureExplanationIncludesBastionEndpoint() async throws {
        let connection = SessionTestSupport.connection(ssh: true)
        await harness.tunnel.setStartError(.connectionFailed(stderrTail: ""))

        do {
            _ = try await harness.manager.connect(connection, password: nil)
            XCTFail("应当抛出 ConnectFailure")
        } catch let failure as ConnectFailure {
            XCTAssertEqual(failure.step, .sshTunnel)
            XCTAssertEqual(failure.title, "SSH 隧道建立失败")
            XCTAssertTrue(failure.explanation.contains("bastion.example.com:22"), failure.explanation)
        }
    }

    func testMySQLUnreachableThroughTunnelMentionsBastionBypass() async throws {
        let connection = SessionTestSupport.connection(ssh: true)
        await harness.mysql.setConnectError(MySQLError.connectionFailure(
            code: 2003,
            sqlState: "HY000",
            message: "Can't connect to MySQL server"
        ))

        do {
            _ = try await harness.manager.connect(connection, password: nil)
            XCTFail("应当抛出 ConnectFailure")
        } catch let failure as ConnectFailure {
            XCTAssertEqual(failure.step, .mysql)
            XCTAssertEqual(failure.explanation, "SSH 隧道建立成功，但无法从跳板机访问 127.0.0.1:3306")
        }
    }

    func testTunnelClosedTitleUsesDisconnectedText() {
        let failure = ConnectFailure(step: .sshTunnel, reason: .ssh(.tunnelClosed(stderrTail: "")))
        XCTAssertEqual(failure.title, "SSH 隧道已断开")
    }

    // MARK: 私钥口令弹窗（`specs/10-ssh-tunnel.md` §3.2）

    func testEncryptedPrivateKeyRequestsPassphraseAndForwardsItToTunnel() async throws {
        let keyPath = try writeTestKey(cipher: "aes256-ctr")
        defer { try? FileManager.default.removeItem(atPath: keyPath) }
        let connection = SessionTestSupport.connection(
            ssh: true,
            sshAuthMethod: .privateKey,
            sshPrivateKeyPath: keyPath
        )
        var captured: SSHSecretRequest?
        harness.manager.sshSecretRequester = { request in
            captured = request
            return "passphrase"
        }

        _ = try await harness.manager.connect(connection, password: nil)

        XCTAssertEqual(captured?.kind, .passphrase)
        XCTAssertEqual(captured?.privateKeyPath, keyPath)
        XCTAssertEqual(harness.tunnel.lastConfiguration?.secret, .passphrase("passphrase"))
    }

    func testUnencryptedPrivateKeyDoesNotPrompt() async throws {
        let keyPath = try writeTestKey(cipher: "none")
        defer { try? FileManager.default.removeItem(atPath: keyPath) }
        let connection = SessionTestSupport.connection(
            ssh: true,
            sshAuthMethod: .privateKey,
            sshPrivateKeyPath: keyPath
        )
        var called = false
        harness.manager.sshSecretRequester = { _ in
            called = true
            return "unused"
        }

        _ = try await harness.manager.connect(connection, password: nil)

        XCTAssertFalse(called)
        XCTAssertNil(harness.tunnel.lastConfiguration?.secret)
    }

    /// 写一个足以让 `SSHPrivateKeyInspector` 读到 ciphername 的 OpenSSH 私钥文件。
    private func writeTestKey(cipher: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tl-test-key-\(UUID().uuidString).pem")
        var data = Data("openssh-key-v1\u{0}".utf8)
        let cipherData = Data(cipher.utf8)
        let length = UInt32(cipherData.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(cipherData)
        data.append(Data(repeating: 0, count: 8))
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(data.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
        try pem.write(to: url, atomically: true, encoding: .utf8)
        return url.path
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
