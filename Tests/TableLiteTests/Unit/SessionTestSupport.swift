import Foundation
@testable import TableLite

/// 会话层单测的装配：临时目录 + InMemory 存储 + 假后端。
@MainActor
struct SessionTestHarness {
    let environment: AppEnvironment
    let layout: AppStorageLayout
    let directory: URL
    let clock: MutableClock
    let mysql: FakeMySQLSession
    let tunnel: FakeSSHTunnel
    let connections: ConnectionStore
    let preferences: Preferences
    let consoleLog: ConsoleLogStore
    let history: QueryHistoryStore
    let drafts: QueryDraftStore
    let sessionState: SessionStateStore

    var manager: SessionManager { environment.sessionManager }

    func clean() {
        StoreTestSupport.remove(directory)
    }
}

@MainActor
enum SessionTestSupport {

    static func makeHarness(layout: AppStorageLayout? = nil) -> SessionTestHarness {
        let made: (layout: AppStorageLayout, directory: URL)
        if let layout {
            made = (layout, layout.rootDirectory)
        } else {
            made = StoreTestSupport.makeTemporaryLayout()
        }
        let clock = MutableClock()
        let preferences = Preferences(store: InMemoryKeyValueStore())
        let credentials = InMemoryCredentialStore()
        let connections = ConnectionStore(layout: made.layout, credentials: credentials)
        let mysql = FakeMySQLSession()
        let tunnel = FakeSSHTunnel(
            configuration: SSHTunnelConfiguration(ssh: SSHConfig(), remoteHost: "127.0.0.1", remotePort: 3306)
        )
        let consoleLog = ConsoleLogStore(capacity: 100, clock: clock)
        let history = QueryHistoryStore(layout: made.layout)
        let drafts = QueryDraftStore(layout: made.layout, clock: clock)
        let sessionState = SessionStateStore(layout: made.layout)
        let factory = SessionBackendFactory(
            makeMySQLSession: { mysql },
            makeTunnel: { _ in tunnel }
        )
        let environment = AppEnvironment(
            layout: made.layout,
            preferences: preferences,
            connections: connections,
            credentials: credentials,
            consoleLog: consoleLog,
            history: history,
            sessionState: sessionState,
            drafts: drafts,
            workspace: WorkspaceStateStore(store: InMemoryKeyValueStore()),
            clock: clock,
            factory: factory
        )
        return SessionTestHarness(
            environment: environment,
            layout: made.layout,
            directory: made.directory,
            clock: clock,
            mysql: mysql,
            tunnel: tunnel,
            connections: connections,
            preferences: preferences,
            consoleLog: consoleLog,
            history: history,
            drafts: drafts,
            sessionState: sessionState
        )
    }

    static func connection(
        id: UUID = UUID(),
        name: String = "本地开发",
        ssh: Bool = false,
        database: String = "app_dev"
    ) -> Connection {
        Connection(
            id: id,
            name: name,
            mysql: MySQLConfig(host: "127.0.0.1", port: 3306, user: "root", database: database),
            ssh: SSHConfig(
                enabled: ssh,
                host: ssh ? "bastion.example.com" : "",
                user: ssh ? "deploy" : ""
            )
        )
    }

    /// 一次成功连接所需的元数据应答。
    static func successfulResponses() -> [(String, MySQLQueryResult)] {
        [
            ("SHOW DATABASES", .single(columns: ["Database"], rows: [["app_dev"], ["mysql"]])),
            ("@@character_set_server", .single(
                columns: ["version", "server_charset", "server_collation", "sql_mode", "client_charset", "connection_collation"],
                rows: [["8.0.36", "utf8mb4", "utf8mb4_0900_ai_ci", "", "utf8mb4", "utf8mb4_general_ci"]]
            )),
            ("TABLE_COLLATION", .single(
                columns: ["TABLE_NAME", "TABLE_TYPE", "ENGINE", "TABLE_ROWS", "TABLE_COMMENT", "TABLE_COLLATION"],
                rows: [["users", "BASE TABLE", "InnoDB", "10", "", "utf8mb4_general_ci"]]
            )),
        ]
    }
}
