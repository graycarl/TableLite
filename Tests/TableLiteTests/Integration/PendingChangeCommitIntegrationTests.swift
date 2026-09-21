import XCTest
@testable import TableLite

/// 变更暂存提交（`PendingChangeEngine` + `PendingChangeCommitter`）真库集成测试。
///
/// 覆盖事务回滚、0 行视为成功、主键被改、以及「截断大字段绝不写回」的安全保证。
/// 设计约束见 docs/tech-designs/08-pending-changes.md §3 §5 §9。
final class PendingChangeCommitIntegrationTests: MySQLIntegrationTestCase {

    override class var databaseName: String { "tablelite_it_pending" }

    private func ref(_ table: String) -> TableRef {
        TableRef(database: Self.databaseName, table: table)
    }

    private func locator(_ columns: [String], _ values: [String]) -> RowLocator {
        RowLocator(columns: columns, values: values.map { CellValue.text($0) })
    }

    private func identity(_ values: [String]) -> RowIdentity {
        .existing(RowIdentity.key(values: values.map { CellValue.text($0) }))
    }

    private func commit(_ engine: PendingChangeEngine) async throws -> CommitOutcome {
        let literalizer = await session.literalizer()
        let statements = engine.sqlStatements(using: literalizer)
        return try await PendingChangeCommitter(session: session).commit(statements, clock: LiveClock()) { _, _ in }
    }

    // MARK: 增删改往返

    func testInsertUpdateDeleteRoundTrip() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_commit")) (
              id INT NOT NULL,
              sub INT NOT NULL,
              name VARCHAR(64),
              body LONGTEXT,
              PRIMARY KEY (id, sub)
            )
            """)
        try await session.execute("""
            INSERT INTO \(qualified("t_commit")) VALUES (2, 1, 'bob', 'x'), (3, 1, 'carol', 'y')
            """)

        let structure = try await tableStructure("t_commit")
        var engine = PendingChangeEngine(table: ref("t_commit"), structure: structure)

        // INSERT
        let inserted = engine.beginInsert()
        engine.setInsertValue(row: inserted, column: "id", value: .text("1"))
        engine.setInsertValue(row: inserted, column: "sub", value: .text("1"))
        engine.setInsertValue(row: inserted, column: "name", value: .text("alice"))
        engine.setInsertValue(row: inserted, column: "body", value: .text("hello"))

        // UPDATE
        let updated = identity(["2", "1"])
        try engine.applyEdit(row: updated,
                             locator: locator(["id", "sub"], ["2", "1"]),
                             column: "name",
                             originalValue: .text("bob"),
                             newValue: .text("bobby"))

        // DELETE
        let deleted = identity(["3", "1"])
        engine.applyDelete(row: deleted, locator: locator(["id", "sub"], ["3", "1"]))

        XCTAssertEqual(engine.stats.inserts, 1)
        XCTAssertEqual(engine.stats.updates, 1)
        XCTAssertEqual(engine.stats.deletes, 1)

        let outcome = try await commit(engine)
        XCTAssertEqual(outcome.executedCount, 3)
        XCTAssertTrue(outcome.zeroRowStatements.isEmpty)

        let result = try await firstResultSet("""
            SELECT id, sub, name, body FROM \(qualified("t_commit")) ORDER BY id
            """)
        let rows = try XCTUnwrap(result?.rows)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map(\.displayText), ["1", "1", "alice", "hello"])
        XCTAssertEqual(rows[1].map(\.displayText), ["2", "1", "bobby", "x"])
    }

    // MARK: 唯一键冲突整体回滚

    func testUniqueConflictRollsBackWholeTransaction() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_unique")) (
              id INT PRIMARY KEY,
              email VARCHAR(64) NOT NULL,
              UNIQUE KEY uq_email (email)
            )
            """)
        try await session.execute("""
            INSERT INTO \(qualified("t_unique")) VALUES (100, 'existing@example.com')
            """)

        let structure = try await tableStructure("t_unique")
        var engine = PendingChangeEngine(table: ref("t_unique"), structure: structure)

        let first = engine.beginInsert()
        engine.setInsertValue(row: first, column: "id", value: .text("1"))
        engine.setInsertValue(row: first, column: "email", value: .text("first@example.com"))

        let second = engine.beginInsert()
        engine.setInsertValue(row: second, column: "id", value: .text("2"))
        engine.setInsertValue(row: second, column: "email", value: .text("existing@example.com"))

        let literalizer = await session.literalizer()
        let statements = engine.sqlStatements(using: literalizer)
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements.map(\.kind), [.insert, .insert])

        do {
            _ = try await PendingChangeCommitter(session: session).commit(statements, clock: LiveClock()) { _, _ in }
            XCTFail("第二条 INSERT 违反唯一键，提交应当失败")
        } catch let failure as CommitFailure {
            XCTAssertEqual(failure.error.code, 1062)
            XCTAssertEqual(failure.statementIndex, 2)
            XCTAssertTrue(failure.rolledBack, "失败后必须回滚")
            XCTAssertFalse(failure.transactionStateUnknown)
        }

        // 第一条（本应成功）也必须被回滚
        let result = try await firstResultSet("SELECT id FROM \(qualified("t_unique")) ORDER BY id")
        XCTAssertEqual(result?.rows.map { $0[0].displayText }, ["100"],
                       "整个事务回滚后只应剩原有的一行")
    }

    // MARK: 影响 0 行视为成功

    func testUpdateAffectingZeroRowsIsSuccess() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_zero")) (id INT PRIMARY KEY, name VARCHAR(20))
            """)
        let structure = try await tableStructure("t_zero")
        var engine = PendingChangeEngine(table: ref("t_zero"), structure: structure)

        try engine.applyEdit(row: identity(["999"]),
                             locator: locator(["id"], ["999"]),
                             column: "name",
                             originalValue: .text("ghost"),
                             newValue: .text("ghost2"))

        let outcome = try await commit(engine)
        XCTAssertEqual(outcome.executedCount, 1)
        XCTAssertEqual(outcome.zeroRowStatements, [1], "更新 0 行是幂等成功，只记录序号")
    }

    // MARK: 主键被改

    func testPrimaryKeyEditUsesOldValueInWhereAndNewValueInSet() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_pk")) (id INT PRIMARY KEY, name VARCHAR(20))
            """)
        try await session.execute("INSERT INTO \(qualified("t_pk")) VALUES (1, 'a')")

        let structure = try await tableStructure("t_pk")
        var engine = PendingChangeEngine(table: ref("t_pk"), structure: structure)
        try engine.applyEdit(row: identity(["1"]),
                             locator: locator(["id"], ["1"]),
                             column: "id",
                             originalValue: .text("1"),
                             newValue: .text("2"))

        let literalizer = await session.literalizer()
        let statements = engine.sqlStatements(using: literalizer)
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].text.contains("SET `id` = 2"), "SET 应当用新值：\(statements[0].text)")
        XCTAssertTrue(statements[0].text.contains("WHERE `id` = 1"), "WHERE 应当用旧值：\(statements[0].text)")

        _ = try await commit(engine)

        let result = try await firstResultSet("SELECT id, name FROM \(qualified("t_pk")) ORDER BY id")
        XCTAssertEqual(result?.rows.map { $0.map(\.displayText) }, [["2", "a"]])
    }

    // MARK: 截断大字段绝不写回

    func testTruncatedLargeColumnIsNotWrittenBackWhenEditingOtherColumn() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_trunc")) (
              id INT PRIMARY KEY,
              name VARCHAR(20),
              body LONGTEXT
            )
            """)
        let fullBody = String(repeating: "abcdefgh", count: 640) // 5120 字符
        let literalizer = await session.literalizer()
        let bodyLiteral = SQLValueLiteral.literal(.text(fullBody), kind: .text, using: literalizer)
        try await session.execute("""
            INSERT INTO \(qualified("t_trunc")) (id, name, body) VALUES (1, 'a', \(bodyLiteral))
            """)

        let structure = try await tableStructure("t_trunc")
        let loader = TableDataLoader(session: session, meta: MetaRepository(session: session, clock: LiveClock()))
        let page = try await loader.loadPage(
            ref: ref("t_trunc"), structure: structure,
            request: TablePageRequest(schema: Self.databaseName, table: "t_trunc",
                                      pageIndex: 0, pageSize: 10,
                                      sort: [], filter: FilterSet()),
            lazyLarge: true, largeThreshold: 4096
        )
        let pageRow = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(pageRow.truncatedLengths["body"], 5120, "首屏读到的 body 应是截断值")

        // 只改非大字段列
        var engine = PendingChangeEngine(table: ref("t_trunc"), structure: structure)
        try engine.applyEdit(row: pageRow.identity,
                             locator: locator(["id"], ["1"]),
                             column: "name",
                             originalValue: .text("a"),
                             newValue: .text("b"))

        let statements = engine.sqlStatements(using: await session.literalizer())
        XCTAssertEqual(statements.count, 1)
        XCTAssertFalse(statements[0].text.contains("`body`"),
                       "只改非大字段列时，截断的大字段列绝不能进入 SET：\(statements[0].text)")

        _ = try await commit(engine)

        let bodyAfter = try await firstResultSet("SELECT body FROM \(qualified("t_trunc")) WHERE id = 1")
        XCTAssertEqual(bodyAfter?.rows.first?.first?.bytes, Array(fullBody.utf8),
                       "数据库里的完整 body 必须原样保留")

        let nameAfter = try await firstResultSet("SELECT name FROM \(qualified("t_trunc")) WHERE id = 1")
        XCTAssertEqual(nameAfter?.rows.first?.first?.displayText, "b")
    }

    // MARK: 空暂存

    func testInsertWithNoValuesUsesServerDefaults() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_default")) (
              id INT PRIMARY KEY AUTO_INCREMENT,
              v INT NOT NULL DEFAULT 7
            )
            """)
        let structure = try await tableStructure("t_default")
        var engine = PendingChangeEngine(table: ref("t_default"), structure: structure)
        _ = engine.beginInsert() // 一列都不填

        let statements = engine.sqlStatements(using: await session.literalizer())
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].text.contains("() VALUES ()"),
                      "一列没填时交给服务器默认值：\(statements[0].text)")

        _ = try await commit(engine)
        let result = try await firstResultSet("""
            SELECT id, v FROM \(qualified("t_default"))
            """)
        XCTAssertEqual(result?.rows.first?.map(\.displayText), ["1", "7"])
    }

    func testEmptyPendingDoesNotOpenTransaction() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_empty")) (id INT PRIMARY KEY)
            """)
        let structure = try await tableStructure("t_empty")
        let engine = PendingChangeEngine(table: ref("t_empty"), structure: structure)

        let counter = QueryCounter()
        await session.setQueryLogger { record in counter.record(record.sql) }
        let outcome = try await commit(engine)
        XCTAssertEqual(outcome.executedCount, 0)
        XCTAssertFalse(counter.all.contains { $0.uppercased().contains("BEGIN") },
                       "空暂存不应开启事务")
    }
}
