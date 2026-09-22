import XCTest
@testable import TableLite

/// `SQLValueLiteral` 的边界：单引号、双引号、反斜杠、换行、NUL、emoji、二进制与 `NO_BACKSLASH_ESCAPES`。
///
/// 规则见 `docs/tech-designs/03-mysql-layer.md` §4.2。
final class SQLValueLiteralTests: XCTestCase {

    // MARK: NULL / 二进制 / 布尔 / 数字

    func testNullLiteral() {
        XCTAssertEqual(SQLValueLiteral.literal(for: SQLValue.null, fieldType: .varString), "NULL")
    }

    func testBinaryLiteralUsesUppercaseHex() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(SQLValueLiteral.literal(for: .binary(data), fieldType: .blob), "0xDEADBEEF")
    }

    func testEmptyBinaryLiteral() {
        XCTAssertEqual(SQLValueLiteral.literal(for: .binary(Data()), fieldType: .blob), "X''")
    }

    func testBoolLiteral() {
        XCTAssertEqual(SQLValueLiteral.literal(for: .bool(true), fieldType: .tiny), "1")
        XCTAssertEqual(SQLValueLiteral.literal(for: .bool(false), fieldType: .tiny), "0")
    }

    func testIntegerLiteralIsUnquotedEvenForStringColumn() {
        XCTAssertEqual(SQLValueLiteral.literal(for: .integer(42), fieldType: .varString), "42")
        XCTAssertEqual(SQLValueLiteral.literal(for: .integer(-7), fieldType: .varString), "-7")
    }

    // MARK: 数字列去引号

    func testNumericColumnUnquotesStrictIntegers() {
        XCTAssertEqual(SQLValueLiteral.literal(for: .text("123"), fieldType: .long), "123")
        XCTAssertEqual(SQLValueLiteral.literal(for: .text("-45"), fieldType: .longlong), "-45")
    }

    func testNumericColumnUnquotesStrictDecimals() {
        XCTAssertEqual(SQLValueLiteral.literal(for: .text("1.5"), fieldType: .newdecimal), "1.5")
        XCTAssertEqual(SQLValueLiteral.literal(for: .text("-0.25"), fieldType: .double), "-0.25")
    }

    func testNumericColumnQuotesNonStrictNumbers() {
        // 不允许 1e5 / 0x1 / 前导 + / 空白 / 无整数部分的 .5 / 无小数部分的 1.
        for invalid in ["1e5", "0x1", "+1", " 1", ".5", "1.", "1,000", ""] {
            XCTAssertEqual(
                SQLValueLiteral.literal(for: .text(invalid), fieldType: .long),
                SQLValueLiteral.quoted(invalid),
                "「\(invalid)」不应被当作数字字面量"
            )
        }
    }

    func testStringColumnAlwaysQuotesNumbers() {
        XCTAssertEqual(SQLValueLiteral.literal(for: .text("123"), fieldType: .varString), "'123'")
    }

    func testDecimalValueFallsBackToStringWhenNotStrict() {
        XCTAssertEqual(SQLValueLiteral.literal(for: .decimal("1.25"), fieldType: .newdecimal), "1.25")
        XCTAssertEqual(SQLValueLiteral.literal(for: .decimal("abc"), fieldType: .newdecimal), "'abc'")
    }

    // MARK: 字符串转义

    func testSingleQuoteEscaping() {
        XCTAssertEqual(
            SQLValueLiteral.literal(for: .text("O'Brien"), fieldType: .varString),
            "'O\\'Brien'"
        )
    }

    func testDoubleQuoteEscaping() {
        XCTAssertEqual(
            SQLValueLiteral.literal(for: .text("a\"b"), fieldType: .varString),
            "'a\\\"b'"
        )
    }

    func testBackslashEscaping() {
        XCTAssertEqual(
            SQLValueLiteral.literal(for: .text("a\\b"), fieldType: .varString),
            "'a\\\\b'"
        )
    }

    func testNewlineAndCarriageReturnAndTabEscaping() {
        XCTAssertEqual(SQLValueLiteral.escape("a\nb"), "a\\nb")
        XCTAssertEqual(SQLValueLiteral.escape("a\rb"), "a\\rb")
        XCTAssertEqual(SQLValueLiteral.escape("a\u{1A}b"), "a\\Zb")
    }

    func testNulByteEscaping() {
        XCTAssertEqual(SQLValueLiteral.escape("a\0b"), "a\\0b")
    }

    func testEmojiIsPreserved() {
        XCTAssertEqual(
            SQLValueLiteral.literal(for: .text("😀"), fieldType: .varString),
            "'😀'"
        )
    }

    func testNoBackslashEscapesOnlyDoublesSingleQuote() {
        XCTAssertEqual(
            SQLValueLiteral.literal(for: .text("O'Brien"), fieldType: .varString, escaping: .noBackslashEscapes),
            "'O''Brien'"
        )
        XCTAssertEqual(
            SQLValueLiteral.literal(for: .text("a\\b"), fieldType: .varString, escaping: .noBackslashEscapes),
            "'a\\b'"
        )
    }

    // MARK: introducer

    func testCharsetIntroducerOnlyForNonUTF8() {
        XCTAssertNil(SQLValueLiteral.charsetIntroducer(for: "utf8mb4"))
        XCTAssertNil(SQLValueLiteral.charsetIntroducer(for: "UTF-8"))
        XCTAssertEqual(SQLValueLiteral.charsetIntroducer(for: "latin1"), "_latin1")
    }

    func testIntroducerIsPrepended() {
        XCTAssertEqual(
            SQLValueLiteral.literal(for: .text("abc"), fieldType: .varString, introducer: "_latin1"),
            "_latin1'abc'"
        )
    }

    // MARK: 严格数字判定

    func testStrictIntegerPredicate() {
        XCTAssertTrue(SQLValueLiteral.isStrictInteger("0"))
        XCTAssertTrue(SQLValueLiteral.isStrictInteger("-0"))
        XCTAssertTrue(SQLValueLiteral.isStrictInteger("12345678901234567890"))
        XCTAssertFalse(SQLValueLiteral.isStrictInteger(""))
        XCTAssertFalse(SQLValueLiteral.isStrictInteger("-"))
        XCTAssertFalse(SQLValueLiteral.isStrictInteger("+1"))
        XCTAssertFalse(SQLValueLiteral.isStrictInteger("1.0"))
        XCTAssertFalse(SQLValueLiteral.isStrictInteger(" 1"))
        XCTAssertFalse(SQLValueLiteral.isStrictInteger("١٢٣"))
    }

    func testStrictDecimalPredicate() {
        XCTAssertTrue(SQLValueLiteral.isStrictDecimal("1.5"))
        XCTAssertTrue(SQLValueLiteral.isStrictDecimal("-0.25"))
        XCTAssertFalse(SQLValueLiteral.isStrictDecimal(".5"))
        XCTAssertFalse(SQLValueLiteral.isStrictDecimal("1."))
        XCTAssertFalse(SQLValueLiteral.isStrictDecimal("1"))
        XCTAssertFalse(SQLValueLiteral.isStrictDecimal("1e5"))
    }

    func testColumnBasedLiteralUsesColumnTypeAndBinaryFlag() {
        let numeric = ColumnInfo(name: "id", fieldType: .long, charsetNumber: 63)
        XCTAssertEqual(SQLValueLiteral.literal(for: .text("7"), column: numeric), "7")

        let binaryColumn = ColumnInfo(name: "payload", fieldType: .blob, charsetNumber: 63)
        XCTAssertEqual(
            SQLValueLiteral.literal(for: .text("abc"), column: binaryColumn),
            "'abc'"
        )
    }
}
