import XCTest
@testable import TableLite

/// 语句拆分边界。见 docs/tech-designs/10-query-editor.md §4 §10。
final class StatementSplitterTests: XCTestCase {

    func testSplitsTwoStatementsAndKeepsSemicolon() {
        let statements = StatementSplitter.split("SELECT 1; SELECT 2")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].text, "SELECT 1;")
        XCTAssertEqual(statements[1].text, " SELECT 2")
        XCTAssertEqual(statements[0].kind, .query)
        XCTAssertEqual(statements[1].kind, .query)
        XCTAssertEqual(statements[0].firstKeyword, "SELECT")
        XCTAssertEqual(statements[0].range, NSRange(location: 0, length: 9))
        XCTAssertEqual(statements[1].range, NSRange(location: 9, length: 9))
    }

    func testTrailingSegmentWithoutSemicolonCounts() {
        let statements = StatementSplitter.split("SELECT 1")
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].text, "SELECT 1")
    }

    func testSemicolonInsideStringIsNotSeparator() {
        let statements = StatementSplitter.split("SELECT ';'; SELECT 2")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].text, "SELECT ';';")
        XCTAssertEqual(statements[1].text, " SELECT 2")
    }

    func testSemicolonInsideCommentIsNotSeparator() {
        let statements = StatementSplitter.split("SELECT 1 /* ; */; SELECT 2")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].text, "SELECT 1 /* ; */;")
    }

    func testVersionCommentDoesNotBreakSplitting() {
        let statements = StatementSplitter.split("SELECT 1 /*! ; */; SELECT 2")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].text, "SELECT 1 /*! ; */;")
    }

    func testPureVersionCommentSegmentIsKeptAsStatement() {
        // `/*! ... */` 会被服务器执行，不能当纯注释丢掉
        let statements = StatementSplitter.split("/*!40101 SET @x = 1 */; SELECT 1")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].kind, .other)
        XCTAssertEqual(statements[0].firstKeyword, "")
        XCTAssertEqual(statements[1].kind, .query)
    }

    func testPureCommentAndEmptySegmentsAreSkipped() {
        let statements = StatementSplitter.split(";; /* c */; SELECT 1")
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].text, " SELECT 1")
        XCTAssertEqual(statements[0].kind, .query)
    }

    func testCommentOnlyInputProducesNoStatements() {
        XCTAssertTrue(StatementSplitter.split("-- just a comment\n/* another */").isEmpty)
        XCTAssertTrue(StatementSplitter.split("   \n\t").isEmpty)
    }

    // MARK: 类型与 firstKeyword

    func testFirstKeywordSkipsLeadingCommentsAndWhitespace() {
        let statements = StatementSplitter.split("  \n /* c */ UPDATE t SET a = 1")
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].firstKeyword, "UPDATE")
        XCTAssertEqual(statements[0].kind, .dml)
    }

    func testStatementKinds() {
        XCTAssertEqual(StatementSplitter.split("INSERT INTO t VALUES (1)").first?.kind, .dml)
        XCTAssertEqual(StatementSplitter.split("DELETE FROM t").first?.kind, .dml)
        XCTAssertEqual(StatementSplitter.split("CREATE TABLE t (id INT)").first?.kind, .ddl)
        XCTAssertEqual(StatementSplitter.split("DROP TABLE t").first?.kind, .ddl)
        XCTAssertEqual(StatementSplitter.split("SET @x = 1").first?.kind, .other)
        XCTAssertEqual(StatementSplitter.split("SHOW TABLES").first?.kind, .query)
    }

    func testTransactionStatements() {
        let statements = StatementSplitter.split("BEGIN; COMMIT;")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].kind, .transaction)
        XCTAssertEqual(statements[1].kind, .transaction)
    }

    func testWithInsertIsDML() {
        // CTE 之后的写关键字必须被判出来
        let statements = StatementSplitter.split(
            "WITH cte AS (SELECT 1) INSERT INTO t SELECT * FROM cte"
        )
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].firstKeyword, "WITH")
        XCTAssertEqual(statements[0].kind, .dml)
    }

    func testWithSelectIsQuery() {
        let statements = StatementSplitter.split(
            "WITH cte AS (SELECT 1) SELECT * FROM cte"
        )
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].kind, .query)
    }
}
