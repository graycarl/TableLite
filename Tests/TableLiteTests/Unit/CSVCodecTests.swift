import XCTest
@testable import TableLite

/// CSV 编解码：引号 / 换行 / 分隔符 / NULL、RFC4180 风格解析、编码与分隔符检测。
///
/// 见 `docs/tech-designs/11-schema-and-import-export.md` §2。
final class CSVCodecTests: XCTestCase {

    // MARK: 写

    func testEncodeSimple() {
        let text = CSVCodec.encodeString(
            header: ["a", "b"],
            rows: [[.text("1"), .text("x")]]
        )
        XCTAssertEqual(text, "a,b\n1,x\n")
    }

    func testEncodeQuotesSpecialCharacters() {
        let text = CSVCodec.encodeString(header: nil, rows: [[
            .text("x,y"), .text("say \"hi\""), .text("line1\nline2"), .text(" padded "),
        ]])
        XCTAssertEqual(text, "\"x,y\",\"say \"\"hi\"\"\",\"line1\nline2\",\" padded \"\n")
    }

    func testEncodeNullRepresentations() {
        XCTAssertEqual(
            CSVCodec.encodeString(header: nil, rows: [[.null]], options: CSVWriteOptions(nullRepresentation: .emptyString)),
            "\n"
        )
        XCTAssertEqual(
            CSVCodec.encodeString(header: nil, rows: [[.null]], options: CSVWriteOptions(nullRepresentation: .nullLiteral)),
            "NULL\n"
        )
    }

    func testEncodeBinaryAsHex() {
        let text = CSVCodec.encodeString(header: nil, rows: [[.binary(Data([0xDE, 0xAD]))]])
        XCTAssertEqual(text, "0xDEAD\n")
    }

    func testEncodeCRLF() {
        let text = CSVCodec.encodeString(
            header: ["a"],
            rows: [[.text("1")]],
            options: CSVWriteOptions(lineEnding: .crlf)
        )
        XCTAssertEqual(text, "a\r\n1\r\n")
    }

    func testEncodeAddsUTF8BOM() {
        let data = CSVCodec.encode(
            header: ["a"],
            rows: [[.text("1")]],
            options: CSVWriteOptions(encoding: .utf8WithBOM)
        )
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func testNeedsQuotingRules() {
        XCTAssertTrue(CSVCodec.needsQuoting("a,b", delimiter: CSVCodec.comma))
        XCTAssertTrue(CSVCodec.needsQuoting("a\"b", delimiter: CSVCodec.comma))
        XCTAssertTrue(CSVCodec.needsQuoting("a\nb", delimiter: CSVCodec.comma))
        XCTAssertTrue(CSVCodec.needsQuoting(" a", delimiter: CSVCodec.comma))
        XCTAssertFalse(CSVCodec.needsQuoting("abc", delimiter: CSVCodec.comma))
    }

    // MARK: 读

    func testParseSimple() throws {
        let result = try CSVCodec.parse(text: "a,b\n1,2\n")
        XCTAssertEqual(result.header, ["a", "b"])
        XCTAssertEqual(result.records, [CSVRecord(fields: ["1", "2"], lineNumber: 2)])
    }

    func testParseQuotedComma() throws {
        let result = try CSVCodec.parse(text: "a,b\n\"x,y\",2\n")
        XCTAssertEqual(result.records.first?.fields, ["x,y", "2"])
    }

    func testParseQuotedNewline() throws {
        let result = try CSVCodec.parse(text: "a,b\n\"line1\nline2\",2\n")
        XCTAssertEqual(result.records.first?.fields, ["line1\nline2", "2"])
        XCTAssertEqual(result.records.first?.lineNumber, 2)
    }

    func testParseDoubledQuote() throws {
        let result = try CSVCodec.parse(text: "a\n\"say \"\"hi\"\"\"\n")
        XCTAssertEqual(result.records.first?.fields, ["say \"hi\""])
    }

    func testParsePreservesSpaces() throws {
        let result = try CSVCodec.parse(text: "a,b\n  x  ,2\n")
        XCTAssertEqual(result.records.first?.fields, ["  x  ", "2"])
    }

    func testParseCRLF() throws {
        let result = try CSVCodec.parse(text: "a,b\r\n1,2\r\n")
        XCTAssertEqual(result.header, ["a", "b"])
        XCTAssertEqual(result.records.first?.fields, ["1", "2"])
    }

    func testParseLoneCR() throws {
        let result = try CSVCodec.parse(text: "a,b\r1,2\r")
        XCTAssertEqual(result.records.first?.fields, ["1", "2"])
    }

    func testParseLastLineWithoutNewline() throws {
        let result = try CSVCodec.parse(text: "a,b\n1,2")
        XCTAssertEqual(result.records.first?.fields, ["1", "2"])
    }

    func testParseEmptyFileThrows() {
        XCTAssertThrowsError(try CSVCodec.parse(text: "")) { error in
            XCTAssertEqual(error as? CSVParseError, .emptyFile)
        }
    }

    func testParseUnclosedQuoteThrowsWithLine() {
        XCTAssertThrowsError(try CSVCodec.parse(text: "a,b\n\"x,2\n")) { error in
            XCTAssertEqual(error as? CSVParseError, .unclosedQuote(line: 2))
        }
    }

    func testParseColumnMismatchThrows() {
        XCTAssertThrowsError(try CSVCodec.parse(text: "a,b\n1,2,3\n")) { error in
            XCTAssertEqual(error as? CSVParseError, .columnCountMismatch(line: 2, expected: 2, actual: 3))
        }
    }

    func testParseFewerColumnsArePadded() throws {
        let result = try CSVCodec.parse(text: "a,b,c\n1\n")
        XCTAssertEqual(result.records.first?.fields, ["1", "", ""])
    }

    func testParseWithoutHeaderUsesFirstRowAsWidth() throws {
        let options = CSVParseOptions(delimiter: CSVCodec.comma, hasHeader: false)
        let result = try CSVCodec.parse(text: "1,2\n3,4\n", options: options)
        XCTAssertNil(result.header)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records[0].fields, ["1", "2"])
    }

    // MARK: 分隔符检测

    func testDetectsTabDelimiter() throws {
        let result = try CSVCodec.parse(text: "a\tb\tc\n1\t2\t3\n")
        XCTAssertEqual(result.delimiter, CSVCodec.tab)
        XCTAssertTrue(result.delimiterWasDetected)
        XCTAssertEqual(result.header, ["a", "b", "c"])
    }

    func testDetectsSemicolonDelimiter() throws {
        let result = try CSVCodec.parse(text: "a;b\n1;2\n")
        XCTAssertEqual(result.delimiter, CSVCodec.semicolon)
    }

    func testDetectsPipeDelimiter() throws {
        let result = try CSVCodec.parse(text: "a|b\n1|2\n")
        XCTAssertEqual(result.delimiter, CSVCodec.pipe)
    }

    func testFallsBackToCommaWhenAmbiguous() throws {
        let result = try CSVCodec.parse(text: "onlyonecolumn\nvalue\n")
        XCTAssertEqual(result.delimiter, CSVCodec.comma)
        XCTAssertFalse(result.delimiterWasDetected)
    }

    func testExplicitDelimiterSkipsDetection() throws {
        let result = try CSVCodec.parse(text: "a,b\n1,2\n", options: CSVParseOptions(delimiter: CSVCodec.semicolon))
        XCTAssertEqual(result.delimiter, CSVCodec.semicolon)
        XCTAssertEqual(result.header, ["a,b"])
    }

    // MARK: 编码检测

    func testStripUTF8BOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: "a,b\n1,2\n".utf8)
        let result = try CSVCodec.parse(data: data)
        XCTAssertEqual(result.encoding, .utf8WithBOM)
        XCTAssertEqual(result.header, ["a", "b"])
    }

    func testDetectGB18030() throws {
        // 「中」的 GB18030 编码是 D6 D0，不是合法 UTF-8。
        let data = Data([0xD6, 0xD0, 0x2C, 0x31, 0x0A])
        let result = try CSVCodec.parse(data: data)
        XCTAssertEqual(result.encoding, .gb18030)
        XCTAssertEqual(result.header, ["中", "1"])
    }

    func testDetectUTF16LittleEndianWithBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append("a,b\n1,2\n".data(using: .utf16LittleEndian)!)
        let result = try CSVCodec.parse(data: data)
        XCTAssertEqual(result.encoding, .utf16LittleEndian)
        XCTAssertEqual(result.header, ["a", "b"])
        XCTAssertEqual(result.records.first?.fields, ["1", "2"])
    }

    func testUnsupportedEncodingThrows() {
        // 裸 GB18030 字节强制按严格 UTF-8 解析应当失败。
        let data = Data([0xD6, 0xD0, 0x2C, 0x31, 0x0A])
        XCTAssertThrowsError(try CSVCodec.parse(data: data, options: CSVParseOptions(encoding: .utf8))) { error in
            XCTAssertEqual(error as? CSVParseError, .unsupportedEncoding)
        }
    }
}
