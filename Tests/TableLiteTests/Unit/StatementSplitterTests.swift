import XCTest
@testable import TableLite

/// 语句拆分器：字符串 / 注释 / 反引号内的分号；结尾无分号；空语句与纯注释跳过。
///
/// 规则见 `docs/tech-designs/10-query-editor.md` §4。
final class StatementSplitterTests: XCTestCase {

    func testSplitsPlainStatements() {
        let statements = StatementSplitter.split("SELECT 1; SELECT 2;")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].text, "SELECT 1;")
        XCTAssertEqual(statements[1].text, "SELECT 2;")
        XCTAssertEqual(statements[0].kind, .query)
    }

    func testSemicolonInsideSingleQuotedStringIsIgnored() {
        let statements = StatementSplitter.split("SELECT ';' AS s;")
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].text, "SELECT ';' AS s;")
    }

    func testSemicolonInsideDoubleQuotedStringIsIgnored() {
        let statements = StatementSplitter.split("SELECT \"a;b\";")
        XCTAssertEqual(statements.count, 1)
    }

    func testSemicolonInsideBacktickIdentifierIsIgnored() {
        let statements = StatementSplitter.split("SELECT `a;b` FROM t;")
        XCTAssertEqual(statements.count, 1)
    }

    func testSemicolonInsideLineCommentIsIgnored() {
        let statements = StatementSplitter.split("SELECT 1 -- ; not a split\n; SELECT 2;")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].text, "SELECT 1 -- ; not a split\n;")
        XCTAssertEqual(statements[1].text, "SELECT 2;")
    }

    func testSemicolonInsideHashCommentIsIgnored() {
        let statements = StatementSplitter.split("SELECT 1 # ;\n; SELECT 2;")
        XCTAssertEqual(statements.count, 2)
    }

    func testSemicolonInsideBlockCommentIsIgnored() {
        let statements = StatementSplitter.split("SELECT 1 /* ; */; SELECT 2;")
        XCTAssertEqual(statements.count, 2)
    }

    func testVersionCommentSemicolonIsIgnored() {
        let statements = StatementSplitter.split("/*!40101 SET @a=1; */ SELECT 1;")
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].kind, .query)
    }

    func testEscapedQuoteInsideString() {
        let statements = StatementSplitter.split("SELECT 'a\\';b';")
        XCTAssertEqual(statements.count, 1)
    }

    func testDoubledQuoteInsideString() {
        let statements = StatementSplitter.split("SELECT 'a'';b';")
        XCTAssertEqual(statements.count, 1)
    }

    func testLastStatementWithoutSemicolonIsKept() {
        let statements = StatementSplitter.split("SELECT 1; SELECT 2")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[1].text, "SELECT 2")
    }

    func testEmptyAndCommentOnlySegmentsAreSkipped() {
        let statements = StatementSplitter.split(";; -- hi\n/* block */ ;")
        XCTAssertTrue(statements.isEmpty)
    }

    func testDoubleDashWithoutWhitespaceIsNotComment() {
        // `1--2` 没有空白，不是注释；仍应作为一条语句。
        let statements = StatementSplitter.split("SELECT 1--2;")
        XCTAssertEqual(statements.count, 1)
    }

    func testRangeUsesUTF16OffsetsWithEmoji() {
        let sql = "SELECT '😀'; SELECT 2;"
        let statements = StatementSplitter.split(sql)
        XCTAssertEqual(statements.count, 2)
        // 第一条语句覆盖前 12 个 UTF-16 单元（emoji 占 2）。
        XCTAssertEqual(statements[0].range, TextRange(location: 0, length: 12))
        XCTAssertEqual(statements[0].kind, .query)
        XCTAssertEqual(statements[1].range, TextRange(location: 13, length: 9))
    }

    func testMultipleKinds() {
        let statements = StatementSplitter.split("SELECT 1; INSERT INTO t VALUES (1); CREATE TABLE t2 (a INT); CALL p();")
        XCTAssertEqual(statements.map(\.kind), [.query, .dml, .ddl, .other])
    }

    func testTrailingSemicolonIsPreserved() {
        let statements = StatementSplitter.split("SELECT 1 ;")
        XCTAssertEqual(statements[0].text, "SELECT 1 ;")
    }
}
