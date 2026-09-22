import XCTest
@testable import TableLite

/// 词法扫描器：token 分类与「字符串 / 注释内不切分」。
///
/// 见 `docs/tech-designs/10-query-editor.md` §3。
final class SQLLexerTests: XCTestCase {

    func testKeywordFunctionAndTypeClassification() {
        let tokens = SQLLexer.tokenize("SELECT COUNT(*) FROM users WHERE id IN (1, 2);")
        func kind(_ text: String) -> SQLTokenKind? {
            tokens.first { $0.text.uppercased() == text }?.kind
        }
        XCTAssertEqual(kind("SELECT"), .keyword)
        XCTAssertEqual(kind("COUNT"), .function)
        XCTAssertEqual(kind("FROM"), .keyword)
        XCTAssertEqual(kind("USERS"), .identifier)
        XCTAssertEqual(kind("WHERE"), .keyword)
    }

    func testTypeClassification() {
        let tokens = SQLLexer.tokenize("CREATE TABLE t (a VARCHAR(20), b BIGINT UNSIGNED)")
        let types = tokens.filter { $0.kind == .type }.map { $0.text.uppercased() }
        XCTAssertTrue(types.contains("VARCHAR"))
        XCTAssertTrue(types.contains("BIGINT"))
    }

    func testFunctionOnlyWhenFollowedByParenthesis() {
        let tokens = SQLLexer.tokenize("SELECT NOW(), left FROM t")
        let now = tokens.first { $0.text.uppercased() == "NOW" }
        let left = tokens.first { $0.text.uppercased() == "LEFT" }
        XCTAssertEqual(now?.kind, .function)
        XCTAssertEqual(left?.kind, .keyword)
    }

    func testStringKeepsCommentAndSemicolonMarkers() {
        let tokens = SQLLexer.tokenize("SELECT 'a -- b; c'")
        let strings = tokens.filter { $0.kind == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(strings[0].text, "'a -- b; c'")
    }

    func testBacktickIdentifierKeepsSemicolon() {
        let tokens = SQLLexer.tokenize("SELECT `a;b`")
        let identifiers = tokens.filter { $0.kind == .quotedIdentifier }
        XCTAssertEqual(identifiers.count, 1)
        XCTAssertEqual(identifiers[0].text, "`a;b`")
    }

    func testLineComments() {
        let tokens = SQLLexer.tokenize("SELECT 1 -- comment\n# another\n")
        let comments = tokens.filter { $0.kind == .comment }.map(\.text)
        XCTAssertEqual(comments, ["-- comment", "# another"])
    }

    func testBlockAndVersionComments() {
        let tokens = SQLLexer.tokenize("/* plain */ /*!40101 SET @a=1 */ SELECT 1")
        let comments = tokens.filter { $0.kind == .comment }.map(\.text)
        XCTAssertEqual(comments, ["/* plain */", "/*!40101 SET @a=1 */"])
    }

    func testNumberFormats() {
        let tokens = SQLLexer.tokenize("1 2.5 .5 1. 1e5 1.5E-3 0xFF")
        XCTAssertEqual(tokens.map(\.text), ["1", "2.5", ".5", "1.", "1e5", "1.5E-3", "0xFF"])
        XCTAssertTrue(tokens.allSatisfy { $0.kind == .number })
    }

    func testVariablesAndParameters() {
        let tokens = SQLLexer.tokenize("SET @a = 1, @@global.b = ?")
        let variables = tokens.filter { $0.kind == .variable }.map(\.text)
        XCTAssertEqual(variables, ["@a", "@@global.b"])
        XCTAssertTrue(tokens.contains { $0.kind == .parameter && $0.text == "?" })
    }

    func testMultiCharacterOperators() {
        let tokens = SQLLexer.tokenize("a <=> b <> c != d := e && f || g")
        let symbols = tokens.filter { $0.kind == .operatorSymbol }.map(\.text)
        XCTAssertEqual(symbols, ["<=>", "<>", "!=", ":=", "&&", "||"])
    }

    func testEmojiStringRangeIsUTF16() {
        let tokens = SQLLexer.tokenize("SELECT '😀'")
        let string = tokens.first { $0.kind == .string }
        XCTAssertEqual(string?.text, "'😀'")
        XCTAssertEqual(string?.range, TextRange(location: 7, length: 4))
    }

    func testUnterminatedBlockCommentConsumesRest() {
        let tokens = SQLLexer.tokenize("SELECT 1 /* never closed")
        XCTAssertTrue(tokens.contains { $0.kind == .comment && $0.text == "/* never closed" })
    }
}
