import XCTest
@testable import TableLite

/// 字面量生成边界。见 docs/tech-designs/03-mysql-layer.md §4.2。
final class SQLValueLiteralTests: XCTestCase {

    private let literalizer = SQLValueLiteralizer.conservative

    private func lit(_ text: String, _ kind: ColumnKind) -> String {
        SQLValueLiteral.literal(CellValue.text(text), kind: kind, using: literalizer)
    }

    // MARK: NULL

    func testNull() {
        XCTAssertEqual(SQLValueLiteral.literal(.null, kind: .text, using: literalizer), "NULL")
        XCTAssertEqual(SQLValueLiteral.literal(.null, kind: .blob, using: literalizer), "NULL")
    }

    // MARK: 字符串转义（保守实现）

    func testSingleQuoteEscaped() {
        XCTAssertEqual(lit("O'Brien", .text), #"'O\'Brien'"#)
    }

    func testDoubleQuoteEscaped() {
        XCTAssertEqual(lit("a\"b", .text), #"'a\"b'"#)
    }

    func testBackslashEscaped() {
        XCTAssertEqual(lit(#"a\b"#, .text), #"'a\\b'"#)
    }

    func testNewlineIsPreserved() {
        XCTAssertEqual(lit("a\nb", .text), "'a\nb'")
    }

    func testNullByteEscaped() {
        XCTAssertEqual(lit("a\u{0}b", .text), #"'a\0b'"#)
    }

    func testEmojiPreserved() {
        XCTAssertEqual(lit("😀", .text), "'😀'")
    }

    func testTextValueOnNonTextColumnStillQuoted() {
        XCTAssertEqual(lit("2024-01-02", .date), "'2024-01-02'")
    }

    // MARK: 二进制

    func testBinaryBecomesUppercaseHex() {
        let value = CellValue.bytes([0x00, 0xAB, 0xFF])
        XCTAssertEqual(SQLValueLiteral.literal(value, kind: .blob, using: literalizer), "0x00ABFF")
    }

    func testEmptyBinaryIsHexLiteral() {
        XCTAssertEqual(SQLValueLiteral.literal(.bytes([]), kind: .blob, using: literalizer), "X''")
    }

    func testInvalidUTF8IsTreatedAsBinary() {
        let value = CellValue.bytes([0xFF, 0xFE])
        XCTAssertEqual(SQLValueLiteral.literal(value, kind: .text, using: literalizer), "0xFFFE")
    }

    func testBitColumnUsesHex() {
        XCTAssertEqual(SQLValueLiteral.literal(.bytes([0x01]), kind: .bit, using: literalizer), "0x01")
    }

    // MARK: 数字严格正则

    func testStrictIntegerAndDecimalStayUnquoted() {
        XCTAssertEqual(lit("42", .integer(isUnsigned: false)), "42")
        XCTAssertEqual(lit("-3.14", .decimal), "-3.14")
        XCTAssertEqual(lit("+0", .integer(isUnsigned: true)).hasPrefix("'"), true, "前导 + 必须带引号")
        XCTAssertEqual(lit("1.5", .integer(isUnsigned: false)), "1.5")
    }

    func testNonStrictNumericFormsAreQuoted() {
        let rejected = ["1e5", "0x1", "+1", " 1", "1 ", "1.", ".5", "- 1", "1,5"]
        for text in rejected {
            let output = lit(text, .integer(isUnsigned: false))
            XCTAssertTrue(output.hasPrefix("'"), "\(text) 应当带引号，实际 \(output)")
            XCTAssertTrue(output.hasSuffix("'"))
        }
    }

    func testNumericTextIsQuotedOnTextField() {
        XCTAssertEqual(lit("42", .text), "'42'")
    }

    func testBooleanColumnIsNotTreatedAsNumeric() {
        XCTAssertEqual(lit("1", .boolean), "'1'")
    }

    // MARK: introducer

    func testNonUTF8CharsetAddsIntroducer() {
        let latin1 = SQLValueLiteralizer(
            charsetName: "latin1",
            escape: SQLValueLiteralizer.conservative.escape
        )
        let output = SQLValueLiteral.literal(CellValue.text("abc"), kind: .text, using: latin1)
        XCTAssertEqual(output, "_latin1'abc'")
    }

    func testUTF8CharsetHasNoIntroducer() {
        let output = SQLValueLiteral.literal(CellValue.text("abc"), kind: .text, using: literalizer)
        XCTAssertEqual(output, "'abc'")
    }
}
