import XCTest
@testable import TableLite

// MARK: - 真库集成测试共享支持
//
// 见 docs/tech-designs/15-testing.md §2：需要真库的测试在没给 `MYSQL_HOST` 时 `XCTSkip`。

enum IntegrationConfiguration {

    /// `MYSQL_HOST` 是否已配置。
    static var isConfigured: Bool {
        guard let host = ProcessInfo.processInfo.environment["MYSQL_HOST"] else { return false }
        return !host.isEmpty
    }

    /// 从环境变量构造 `MySQLSession.Configuration`；缺 `MYSQL_HOST` 时抛 `XCTSkip`。
    static func make(queryTimeout: Int = 300) throws -> MySQLSession.Configuration {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MYSQL_HOST"], !host.isEmpty else {
            throw XCTSkip("未设置 MYSQL_HOST，跳过真库集成测试")
        }
        var mysql = MySQLConnectConfig()
        mysql.host = host
        mysql.port = Int(env["MYSQL_PORT"] ?? "3306") ?? 3306
        mysql.user = env["MYSQL_USER"] ?? "root"
        mysql.database = env["MYSQL_DATABASE"] ?? ""
        mysql.queryTimeout = queryTimeout
        return MySQLSession.Configuration(mysql: mysql,
                                          password: env["MYSQL_PASSWORD"],
                                          host: host,
                                          port: mysql.port)
    }
}

/// 真库集成测试基类：每个用例一个独立 session + 一个专属库。
///
/// - `setUp`：连接 → `CREATE DATABASE` → `USE`；
/// - `tearDown`：`DROP DATABASE` → 关闭连接。
class MySQLIntegrationTestCase: XCTestCase {

    /// 子类覆盖成各自专属的库名，避免不同测试类相互清理。
    class var databaseName: String { "tablelite_it" }

    private(set) var session: MySQLSession!

    override func setUp() async throws {
        let configuration = try IntegrationConfiguration.make()
        let session = MySQLSession(configuration: configuration, clock: LiveClock())
        self.session = session
        try await session.open()
        try await session.execute("CREATE DATABASE IF NOT EXISTS `\(Self.databaseName)`")
        try await session.execute("USE `\(Self.databaseName)`")
    }

    override func tearDown() async throws {
        if let session {
            _ = try? await session.execute("DROP DATABASE IF EXISTS `\(Self.databaseName)`")
            await session.close()
        }
        session = nil
    }

    /// 限定到本用例专属库的表名（已加反引号）。
    func qualified(_ table: String) -> String {
        "`\(Self.databaseName)`.`\(table)`"
    }

    /// 读一页需要的元数据（走真库 `information_schema`）。
    func tableStructure(_ table: String) async throws -> TableStructure {
        let meta = MetaRepository(session: session, clock: LiveClock())
        return try await meta.structure(TableRef(database: Self.databaseName, table: table))
    }

    /// 查询并取第一个结果集。
    func firstResultSet(_ sql: String) async throws -> MaterializedResultSet? {
        let results = try await session.queryAll(sql, unbuffered: false)
        return MaterializedResultSet.firstResultSet(in: results)
    }
}

/// 线程安全的下发语句计数器（`setQueryLogger` 的回调是 `@Sendable`）。
final class QueryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var sqls: [String] = []

    func record(_ sql: String) {
        lock.lock(); defer { lock.unlock() }
        sqls.append(sql)
    }

    func count(matching needle: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sqls.filter { $0.contains(needle) }.count
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        sqls.removeAll()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return sqls
    }
}
