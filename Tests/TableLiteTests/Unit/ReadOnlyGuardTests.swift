import XCTest
@testable import TableLite

/// 只读模式白名单。见 docs/tech-designs/10-query-editor.md §10、specs/09-readonly-mode.md §4。
final class ReadOnlyGuardTests: XCTestCase {

    private func evaluate(_ sql: String) -> ReadOnlyDecision {
        guard let statement = StatementSplitter.split(sql).first else {
            return .rejected(reason: ReadOnlyGuard.rejectionMessage)
        }
        return ReadOnlyGuard.evaluate(statement)
    }

    private func assertAllowed(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(evaluate(sql), .allowed, "应当放行：\(sql)", file: file, line: line)
    }

    private func assertRejected(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(evaluate(sql), .rejected(reason: ReadOnlyGuard.rejectionMessage),
                       "应当拒绝：\(sql)", file: file, line: line)
    }

    // MARK: 白名单

    func testWhitelistedQueriesAreAllowed() {
        assertAllowed("SELECT 1")
        assertAllowed("  select * from t where name = 'x'")
        assertAllowed("SHOW TABLES")
        assertAllowed("EXPLAIN SELECT 1")
        assertAllowed("DESCRIBE users")
        assertAllowed("DESC users")
        assertAllowed("/* hint */ SELECT 1")
    }

    func testWithSelectIsAllowed() {
        assertAllowed("WITH cte AS (SELECT 1) SELECT * FROM cte")
        assertAllowed("WITH RECURSIVE cte AS (SELECT 1) SELECT * FROM cte")
        assertAllowed("WITH a AS (SELECT 1), b AS (SELECT 2) SELECT * FROM a, b")
    }

    // MARK: WITH 写操作

    func testWithWriteStatementsAreRejected() {
        assertRejected("WITH cte AS (SELECT 1) INSERT INTO t SELECT * FROM cte")
        assertRejected("WITH cte AS (SELECT 1) UPDATE t SET a = 1")
        assertRejected("WITH cte AS (SELECT 1) DELETE FROM t")
        assertRejected("WITH cte AS (SELECT 1) REPLACE INTO t SELECT * FROM cte")
        // 只有 CTE、没有主语句 → 拒绝
        assertRejected("WITH cte AS (SELECT 1)")
    }

    // MARK: 各类写 / 会话语句

    func testWriteAndSessionStatementsAreRejected() {
        assertRejected("INSERT INTO t VALUES (1)")
        assertRejected("UPDATE t SET a = 1")
        assertRejected("DELETE FROM t")
        assertRejected("REPLACE INTO t VALUES (1)")
        assertRejected("CREATE TABLE t (id INT)")
        assertRejected("ALTER TABLE t ADD COLUMN a INT")
        assertRejected("DROP TABLE t")
        assertRejected("TRUNCATE TABLE t")
        assertRejected("RENAME TABLE a TO b")
        assertRejected("GRANT SELECT ON *.* TO u")
        assertRejected("REVOKE SELECT ON *.* FROM u")
        assertRejected("SET @x = 1")
        assertRejected("CALL p()")
        assertRejected("LOAD DATA INFILE 'x' INTO TABLE t")
        assertRejected("LOCK TABLES t READ")
        assertRejected("UNLOCK TABLES")
        assertRejected("BEGIN")
        assertRejected("COMMIT")
        assertRejected("ROLLBACK")
    }

    // MARK: 文案

    func testRejectionMessage() {
        XCTAssertEqual(ReadOnlyGuard.rejectionMessage, "只读模式：写操作已被禁用")
        XCTAssertEqual(evaluate("DELETE FROM t"),
                       .rejected(reason: "只读模式：写操作已被禁用"))
    }

    func testEmptyOrCommentOnlyInputIsRejected() {
        assertRejected("-- nothing here")
        assertRejected("   ")
    }
}
