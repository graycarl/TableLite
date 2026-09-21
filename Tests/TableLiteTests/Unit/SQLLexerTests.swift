import XCTest
@testable import TableLite

/// 词法扫描边界。见 docs/tech-designs/10-query-editor.md §3。
final class SQLLexerTests: XCTestCase {

    private func tokens(_ sql: String) -> [SQLToken] { SQLLexer.tokenize(sql) }
    private func kinds(_ sql: String) -> [SQLTokenKind] { tokens(sql).map(\.kind) }

    // MARK: 字符串

    func testStringSwallowsDoubleDashAndSemicolon() {
        let sql = "SELECT '--;'"
        let result = tokens(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].kind, .keyword)
        XCTAssertEqual(result[1].kind, .string)
        XCTAssertEqual(SQLLexer.text(of: result[1], in: sql), "'--;'")
    }

    func testDoubledSingleQuoteEscape() {
        let sql = "SELECT 'it''s'"
        let result = tokens(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(SQLLexer.text(of: result[1], in: sql), "'it''s'")
        XCTAssertEqual(result[1].kind, .string)
    }

    func testBackslashEscapedSingleQuote() {
        let sql = #"SELECT 'a\'b'"#
        let result = tokens(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(SQLLexer.text(of: result[1], in: sql), #"'a\'b'"#)
    }

    func testDoubleQuotedStringWithDoubledQuote() {
        let sql = #"SELECT "a""b""#
        let result = tokens(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].kind, .string)
        XCTAssertEqual(SQLLexer.text(of: result[1], in: sql), #""a""b""#)
    }

    func testDoubleQuotedStringWithBackslashEscape() {
        let sql = #"SELECT "a\"b""#
        let result = tokens(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].kind, .string)
        XCTAssertEqual(SQLLexer.text(of: result[1], in: sql), #""a\"b""#)
    }

    // MARK: 反引号

    func testBacktickKeepsSemicolonAndDoubledBacktick() {
        let sql = "SELECT `a;b``c`"
        let result = tokens(sql)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].kind, .backtick)
        XCTAssertEqual(SQLLexer.text(of: result[1], in: sql), "`a;b``c`")
    }

    // MARK: 注释

    func testVersionCommentIsOneCommentToken() {
        let sql = "/*!40101 SET @x = 1 */"
        let result = tokens(sql)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .comment)
        XCTAssertEqual(SQLLexer.text(of: result[0], in: sql), sql)
    }

    func testHashCommentRunsToEndOfLine() {
        let sql = "SELECT 1 # c;\n2"
        let result = tokens(sql)
        XCTAssertEqual(result.map(\.kind), [.keyword, .number, .comment, .number])
        XCTAssertEqual(SQLLexer.text(of: result[2], in: sql), "# c;")
        XCTAssertEqual(result[3].range.location, 14)
    }

    func testDoubleDashNeedsWhitespaceToBeComment() {
        // `1--2` 在 MySQL 里是 1 减负 2，不是注释
        XCTAssertEqual(kinds("SELECT 1--2"),
                       [.keyword, .number, .operatorSymbol, .operatorSymbol, .number])
        // `-- x` 才是注释
        XCTAssertEqual(kinds("SELECT 1 -- x"), [.keyword, .number, .comment])
        // `--` 结尾也是注释
        XCTAssertEqual(kinds("SELECT 1 --"), [.keyword, .number, .comment])
    }

    // MARK: UTF-16 range

    func testEmojiRangeIsUTF16Based() {
        let sql = "SELECT '😀', 1"
        let result = tokens(sql)
        XCTAssertEqual(result[1].kind, .string)
        XCTAssertEqual(result[1].range, NSRange(location: 7, length: 4))
        XCTAssertEqual(SQLLexer.text(of: result[1], in: sql), "'😀'")
        // emoji 之后仍能正确继续扫描
        XCTAssertEqual(result.last?.kind, .number)
    }

    // MARK: 变量 / 参数

    func testVariablesAndParameter() {
        let sql = "SELECT @v, @@global.x, ?"
        let result = tokens(sql)
        let texts = result.map { SQLLexer.text(of: $0, in: sql) }
        XCTAssertEqual(result[1].kind, .variable)
        XCTAssertEqual(texts[1], "@v")
        XCTAssertEqual(result[3].kind, .variable)
        XCTAssertEqual(texts[3], "@@global.x")
        XCTAssertEqual(result.last?.kind, .parameter)
        XCTAssertEqual(texts.last, "?")
    }

    // MARK: 分类

    func testKeywordFunctionTypeIdentifierClassification() {
        let sql = "SELECT COUNT(*) FROM t"
        XCTAssertEqual(kinds(sql),
                       [.keyword, .function, .punctuation, .operatorSymbol, .punctuation, .keyword, .identifier])

        let ddl = "CREATE TABLE t (id INT)"
        XCTAssertTrue(tokens(ddl).contains { $0.kind == .type })
    }

    func testNumberForms() {
        for text in ["1", "1.5", ".5", "0xFF", "1e5"] {
            let result = tokens(text)
            XCTAssertEqual(result.count, 1, "\(text) 应当是一个 token")
            XCTAssertEqual(result[0].kind, .number, "\(text) 应当是数字")
        }
    }
}
