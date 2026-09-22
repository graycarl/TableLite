import XCTest
@testable import TableLite

/// `ConnectionListViewModel`：加载、过滤、增删改、连接编排、测试连接。
@MainActor
final class ConnectionListViewModelTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    private func makeViewModel() -> ConnectionListViewModel {
        ConnectionListViewModel(environment: harness.environment)
    }

    // MARK: 加载与过滤

    func testLoadReadsConnections() async throws {
        try await harness.connections.upsert(StoreTestSupport.connection(name: "本地开发"))
        let viewModel = makeViewModel()

        await viewModel.load()

        XCTAssertEqual(viewModel.connections.map(\.name), ["本地开发"])
        XCTAssertTrue(viewModel.notices.isEmpty)
    }

    func testLoadSurfacesSecretFieldNotice() async throws {
        let json = """
        {"schemaVersion":1,"connections":[{"id":"\(UUID().uuidString)","name":"本地","color":"none",\
        "isReadOnly":false,"mysql":{"host":"127.0.0.1","port":3306,"user":"root","database":"app_dev",\
        "charset":"utf8mb4","useSSL":true,"skipCertificateVerification":false,"connectTimeout":10,\
        "queryTimeout":300,"keepAlive":true,"keepAliveInterval":30,"password":"oops"},\
        "ssh":{"enabled":false,"host":"","port":22,"user":"","authMethod":"sshConfigOrAgent",\
        "useSSHConfigAlias":false},"createdAt":0,"updatedAt":0}]}
        """
        try Data(json.utf8).write(to: harness.layout.connectionsFile)

        let viewModel = makeViewModel()
        await viewModel.load()

        XCTAssertEqual(viewModel.connections.count, 1)
        XCTAssertEqual(viewModel.notices.count, 1)
        XCTAssertTrue(viewModel.notices[0].contains("密码字段"))
    }

    func testFilterMatchesNameAndSummary() async throws {
        try await harness.connections.upsert(StoreTestSupport.connection(name: "本地开发"))
        try await harness.connections.upsert(StoreTestSupport.connection(name: "预发布"))
        let viewModel = makeViewModel()
        await viewModel.load()

        viewModel.searchText = "本地"
        XCTAssertEqual(viewModel.filteredConnections.map(\.name), ["本地开发"])

        viewModel.searchText = "127.0.0.1"
        XCTAssertEqual(viewModel.filteredConnections.count, 2)

        viewModel.searchText = "找不到的关键字"
        XCTAssertTrue(viewModel.filteredConnections.isEmpty)
    }

    // MARK: 状态

    func testStatusReflectsSessionState() async throws {
        let connection = StoreTestSupport.connection()
        try await harness.connections.upsert(connection)
        let viewModel = makeViewModel()
        await viewModel.load()

        XCTAssertEqual(viewModel.status(for: connection), .notConnected)
        XCTAssertFalse(viewModel.hasReconnectableSessions)

        _ = try await harness.manager.connect(connection, password: nil)
        XCTAssertEqual(viewModel.status(for: connection), .connected)
        XCTAssertFalse(viewModel.hasReconnectableSessions)

        await harness.manager.disconnect(id: connection.id)
        XCTAssertEqual(viewModel.status(for: connection), .needsReconnect)
        XCTAssertTrue(viewModel.hasReconnectableSessions)
    }

    // MARK: 增删改

    func testSaveCurrentFormPersistsConnectionAndPassword() async throws {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.beginCreate()
        viewModel.formState.name = "新连接"
        viewModel.formState.host = "127.0.0.1"
        viewModel.formState.user = "root"
        viewModel.formState.password = "secret"

        let outcome = await viewModel.saveCurrentForm()

        XCTAssertNotNil(outcome)
        XCTAssertFalse(viewModel.isFormPresented)
        XCTAssertEqual(viewModel.connections.count, 1)
        let saved = try XCTUnwrap(viewModel.connections.first)
        XCTAssertEqual(saved.name, "新连接")
        XCTAssertEqual(try harness.environment.credentials.password(for: saved.id, kind: .mysqlPassword), "secret")
        XCTAssertEqual(outcome?.sessionPassword, "secret")
    }

    func testSaveCurrentFormRejectsInvalidConfiguration() async throws {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.beginCreate()
        viewModel.formState.name = ""
        viewModel.formState.host = ""
        viewModel.formState.user = ""

        let outcome = await viewModel.saveCurrentForm()

        XCTAssertNil(outcome)
        XCTAssertTrue(viewModel.connections.isEmpty)
    }

    func testSaveAndConnectCurrentFormOpensSession() async throws {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.beginCreate()
        viewModel.formState.name = "新连接"
        viewModel.formState.host = "127.0.0.1"
        viewModel.formState.user = "root"
        viewModel.formState.password = "secret"

        await viewModel.saveAndConnectCurrentForm()

        XCTAssertEqual(harness.manager.sessions.count, 1)
        XCTAssertTrue(harness.manager.sessions[0].state.isConnected)
    }

    func testDuplicateCopiesCredentialsToNewConnection() async throws {
        let original = StoreTestSupport.connection(name: "生产")
        try await harness.connections.upsert(original)
        try harness.environment.credentials.setPassword("secret", for: original.id, kind: .mysqlPassword)
        let viewModel = makeViewModel()
        await viewModel.load()

        await viewModel.duplicate(original)

        XCTAssertEqual(viewModel.connections.count, 2)
        let copy = try XCTUnwrap(viewModel.connections.first { $0.id != original.id })
        XCTAssertEqual(copy.name, "生产 副本")
        XCTAssertEqual(try harness.environment.credentials.password(for: copy.id, kind: .mysqlPassword), "secret")
    }

    func testDeleteRemovesConnectionAndCredentials() async throws {
        let connection = StoreTestSupport.connection()
        try await harness.connections.upsert(connection)
        try harness.environment.credentials.setPassword("secret", for: connection.id, kind: .mysqlPassword)
        let viewModel = makeViewModel()
        await viewModel.load()

        await viewModel.delete(connection)

        XCTAssertTrue(viewModel.connections.isEmpty)
        XCTAssertNil(try harness.environment.credentials.password(for: connection.id, kind: .mysqlPassword))
    }

    // MARK: 连接

    func testConnectUsesStoredPassword() async throws {
        let connection = StoreTestSupport.connection()
        try await harness.connections.upsert(connection)
        try harness.environment.credentials.setPassword("secret", for: connection.id, kind: .mysqlPassword)
        let viewModel = makeViewModel()
        await viewModel.load()

        await viewModel.connect(connection)

        XCTAssertNil(viewModel.passwordPrompt)
        XCTAssertNil(viewModel.failurePresentation)
        XCTAssertEqual(harness.manager.sessions.count, 1)
        XCTAssertTrue(harness.manager.sessions[0].state.isConnected)
        let parameters = await harness.mysql.currentParameters
        XCTAssertEqual(parameters?.password, "secret")
    }

    func testConnectWithoutStoredPasswordPrompts() async throws {
        let connection = StoreTestSupport.connection()
        try await harness.connections.upsert(connection)
        let viewModel = makeViewModel()
        await viewModel.load()

        await viewModel.connect(connection)

        XCTAssertNotNil(viewModel.passwordPrompt)
        XCTAssertTrue(harness.manager.sessions.isEmpty)
    }

    func testSubmitPasswordPromptConnectsAndRemembers() async throws {
        let connection = StoreTestSupport.connection()
        try await harness.connections.upsert(connection)
        let viewModel = makeViewModel()
        await viewModel.load()
        await viewModel.connect(connection)
        XCTAssertNotNil(viewModel.passwordPrompt)

        await viewModel.submitPasswordPrompt(password: "typed", remember: true)

        XCTAssertNil(viewModel.passwordPrompt)
        XCTAssertEqual(harness.manager.sessions.count, 1)
        XCTAssertEqual(try harness.environment.credentials.password(for: connection.id, kind: .mysqlPassword), "typed")
    }

    func testConnectionFailurePresentsDetails() async throws {
        let connection = StoreTestSupport.connection()
        try await harness.connections.upsert(connection)
        try harness.environment.credentials.setPassword("secret", for: connection.id, kind: .mysqlPassword)
        await harness.mysql.setConnectError(MySQLError(
            kind: .authentication, code: 1045, sqlState: "28000", message: "Access denied"
        ))
        let viewModel = makeViewModel()
        await viewModel.load()

        await viewModel.connect(connection)

        let presentation = try XCTUnwrap(viewModel.failurePresentation)
        XCTAssertEqual(presentation.failure.step, .mysql)
        XCTAssertEqual(presentation.connection?.id, connection.id)
    }

    // MARK: 测试连接

    func testRunCurrentFormTestReportsSuccessWithoutSSH() async throws {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.beginCreate()
        viewModel.formState.name = "新连接"
        viewModel.formState.host = "127.0.0.1"
        viewModel.formState.user = "root"

        await viewModel.runCurrentFormTest()

        XCTAssertFalse(viewModel.isTesting)
        XCTAssertTrue(viewModel.isTestPresented)
        let report = try XCTUnwrap(viewModel.testReport)
        XCTAssertTrue(report.succeeded)
        XCTAssertEqual(report.steps.map(\.step), [.mysql, .serverInfo])
    }

    func testRunCurrentFormTestReportsMySQLFailure() async throws {
        await harness.mysql.setConnectError(MySQLError(
            kind: .authentication, code: 1045, sqlState: "28000", message: "Access denied"
        ))
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.beginCreate()
        viewModel.formState.name = "新连接"
        viewModel.formState.host = "127.0.0.1"
        viewModel.formState.user = "root"

        await viewModel.runCurrentFormTest()

        let report = try XCTUnwrap(viewModel.testReport)
        XCTAssertFalse(report.succeeded)
        XCTAssertEqual(report.failure?.step, .mysql)
        XCTAssertEqual(report.steps.first { $0.step == .mysql }?.failure?.mysqlError?.code, 1045)
        XCTAssertEqual(report.steps.first { $0.step == .serverInfo }?.outcome, .skipped)
    }

    func testTestConnectionDoesNotPersistAnything() async throws {
        let viewModel = makeViewModel()
        await viewModel.load()
        viewModel.beginCreate()
        viewModel.formState.name = "新连接"
        viewModel.formState.host = "127.0.0.1"
        viewModel.formState.user = "root"

        await viewModel.runCurrentFormTest()

        XCTAssertTrue(viewModel.connections.isEmpty)
        XCTAssertTrue(harness.manager.sessions.isEmpty)
    }
}
