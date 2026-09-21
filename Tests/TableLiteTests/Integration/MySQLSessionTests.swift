import XCTest
@testable import TableLite

/// `MySQLSession` 的集成测试。需要真数据库，依赖环境变量：
/// `MYSQL_HOST` / `MYSQL_PORT` / `MYSQL_USER` / `MYSQL_PASSWORD` / `MYSQL_DATABASE`。
/// 没给 `MYSQL_HOST` 就 `XCTSkip`。见 `docs/tech-designs/15-testing.md` §2。
///
/// 覆盖：连接 + `SELECT 1`、多语句与 `CALL` 多结果集、特殊字符往返、
/// 取消长查询（用有真实执行计划的查询，见 `docs/03` §8.1）、错误映射。
final class MySQLSessionTests: XCTestCase {

    private static let testDatabase = "tablelite_it"
    private static let tableName = "tl_session_rt"
    private static let bigTableName = "tl_session_big"
    private static let procedureName = "tl_session_proc"

    private var session: MySQLSession?

    // MARK: 环境

    private func requireConfiguration() throws -> MySQLSession.Configuration {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MYSQL_HOST"], !host.isEmpty else {
            throw XCTSkip("未设置 MYSQL_HOST，跳过 MySQLSession 集成测试")
        }
        var mysql = MySQLConnectConfig()
        mysql.host = host
        mysql.port = Int(env["MYSQL_PORT"] ?? "3306") ?? 3306
        mysql.user = env["MYSQL_USER"] ?? "root"
        mysql.database = env["MYSQL_DATABASE"] ?? ""
        mysql.queryTimeout = 300
        return MySQLSession.Configuration(mysql: mysql,
                                          password: env["MYSQL_PASSWORD"],
                                          host: host,
                                          port: mysql.port)
    }

    private func openSession(queryTimeout: Int = 300) async throws -> MySQLSession {
        var configuration = try requireConfiguration()
        configuration.mysql.queryTimeout = queryTimeout

        let session = MySQLSession(configuration: configuration, clock: LiveClock())
        self.session = session
        try await session.open()

        // 用独立的测试库，避免污染目标库
        try await session.execute("CREATE DATABASE IF NOT EXISTS `\(Self.testDatabase)`")
        try await session.execute("USE `\(Self.testDatabase)`")
        return session
    }

    override func tearDown() async throws {
        if let session {
            _ = try? await session.execute("DROP TABLE IF EXISTS `\(Self.testDatabase)`.`\(Self.tableName)`")
            _ = try? await session.execute("DROP TABLE IF EXISTS `\(Self.testDatabase)`.`\(Self.bigTableName)`")
            _ = try? await session.execute("DROP PROCEDURE IF EXISTS `\(Self.testDatabase)`.`\(Self.procedureName)`")
            await session.close()
        }
        session = nil
    }

    // MARK: 连接

    func testConnectAndSelectOne() async throws {
        let session = try await openSession()
        let open = await session.isOpen
        XCTAssertTrue(open, "open() 之后连接应当可用")

        let version = await session.serverVersion
        XCTAssertFalse(version.isEmpty, "应当读到服务器版本")

        let info = await session.serverInfo
        XCTAssertNotNil(info)
        XCTAssertFalse(info?.charset.isEmpty ?? true, "应当读到字符集")

        let results = try await session.queryAll("SELECT 1 AS one", unbuffered: false)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.header.columns.count, 1)
        XCTAssertEqual(results.first?.header.columns.first?.name, "one")
        XCTAssertEqual(results.first?.rows.first?.first?.displayText, "1")
    }

    func testMultiStatementAndCallReturnAllResultSets() async throws {
        let session = try await openSession()

        // 一次下发多条语句
        let multi = try await session.queryAll("SELECT 1 AS a; SELECT 2 AS b;", unbuffered: false)
        XCTAssertEqual(multi.count, 2)
        XCTAssertEqual(multi[0].rows.first?.first?.displayText, "1")
        XCTAssertEqual(multi[1].rows.first?.first?.displayText, "2")

        // 单条 CALL 本身可能返回多个结果集
        try await session.execute("DROP PROCEDURE IF EXISTS `\(Self.testDatabase)`.`\(Self.procedureName)`")
        try await session.execute("""
            CREATE PROCEDURE `\(Self.testDatabase)`.`\(Self.procedureName)`()
            BEGIN
              SELECT 11 AS a;
              SELECT 22 AS b;
            END
            """)

        let call = try await session.queryAll("CALL `\(Self.testDatabase)`.`\(Self.procedureName)`()",
                                              unbuffered: false)
        let withColumns = call.filter(\.header.isResultSet)
        XCTAssertEqual(withColumns.count, 2)
        XCTAssertEqual(withColumns[0].rows.first?.first?.displayText, "11")
        XCTAssertEqual(withColumns[1].rows.first?.first?.displayText, "22")
    }

    // MARK: 特殊字符往返

    func testSpecialCharactersRoundTrip() async throws {
        let session = try await openSession()
        let table = "`\(Self.testDatabase)`.`\(Self.tableName)`"

        try await session.execute("DROP TABLE IF EXISTS \(table)")
        try await session.execute("""
            CREATE TABLE \(table) (
              id INT PRIMARY KEY AUTO_INCREMENT,
              t TEXT,
              b VARBINARY(255)
            )
            """)

        let literalizer = await session.literalizer()
        let cases: [(text: String, binary: [UInt8])] = [
            ("单引号 O'Reilly，反斜杠 \\，emoji 😀，换行\n制表\t", [0x00, 0x1B, 0x27, 0x5C, 0xFF, 0xFE]),
            ("nul\u{0}inside", []),
            ("", [0x00]),
        ]

        for item in cases {
            let escaped = literalizer.escape(item.text)
            let binaryLiteral = item.binary.isEmpty
                ? "X''"
                : "0x" + item.binary.map { String(format: "%02X", $0) }.joined()
            try await session.execute("INSERT INTO \(table) (t, b) VALUES ('\(escaped)', \(binaryLiteral))")
        }

        let results = try await session.queryAll("SELECT t, b FROM \(table) ORDER BY id", unbuffered: false)
        let rows = results.first?.rows ?? []
        XCTAssertEqual(rows.count, cases.count)

        for (index, item) in cases.enumerated() {
            XCTAssertEqual(rows[index][0].bytes, [UInt8](item.text.utf8),
                           "第 \(index + 1) 行文本不一致")
            XCTAssertEqual(rows[index][1].bytes, item.binary,
                           "第 \(index + 1) 行二进制不一致")
        }
    }

    // MARK: 取消

    func testCancelLongQuery() async throws {
        let session = try await openSession(queryTimeout: 60)
        let big = "`\(Self.testDatabase)`.`\(Self.bigTableName)`"

        try await session.execute("DROP TABLE IF EXISTS \(big)")
        try await session.execute("""
            CREATE TABLE \(big) (
              id INT PRIMARY KEY AUTO_INCREMENT,
              payload VARCHAR(64)
            )
            """)

        // 造足够多的行，让自连接撑过取消前的等待（约 50000 行 → 自连接极慢）
        let batch = Array(repeating: "(REPEAT('x',64))", count: 1000).joined(separator: ",")
        for _ in 0..<50 {
            try await session.execute("INSERT INTO \(big) (payload) VALUES \(batch)")
        }

        // 不能拿 SLEEP()/BENCHMARK() 当受害者：被 KILL 后会吞掉中断。
        // `WHERE a.id > b.id` 强制嵌套循环。见 docs/tech-designs/03-mysql-layer.md §8.1。
        let queryTask = Task { () -> MySQLError? in
            do {
                for try await _ in await session.query(
                    "SELECT COUNT(*) FROM \(big) a, \(big) b WHERE a.id > b.id",
                    unbuffered: false
                ) {}
                return nil
            } catch let error as MySQLError {
                return error
            } catch {
                return .internalError(String(describing: error))
            }
        }

        try await Task.sleep(for: .milliseconds(800))
        await session.cancelCurrentQuery()
        let error = await queryTask.value

        guard let error else {
            return XCTFail("长查询没有抛错，取消链路未生效")
        }
        XCTAssertTrue(error.isCancelled, "期望取消 / 超时，实得 \(error)")

        // KILL QUERY 只杀语句：连接（必要时重建后）仍可继续使用
        let after = try await session.queryAll("SELECT 1", unbuffered: false)
        XCTAssertEqual(after.first?.rows.first?.first?.displayText, "1")
    }

    // MARK: 错误映射

    func testSyntaxErrorMapsToServerError() async throws {
        let session = try await openSession()
        do {
            _ = try await session.queryAll("SELEC 1", unbuffered: false)
            XCTFail("语法错误应当抛错")
        } catch let error as MySQLError {
            guard case .server(let serverError) = error else {
                return XCTFail("期望 .server，实得 \(error)")
            }
            XCTAssertEqual(serverError.code, 1064, "语法错误码应当是 1064")
            XCTAssertFalse(serverError.sqlState.isEmpty, "SQLSTATE 不应为空")
            XCTAssertEqual(serverError.sql, "SELEC 1", "错误里应当带出错语句")
        }
    }
}
