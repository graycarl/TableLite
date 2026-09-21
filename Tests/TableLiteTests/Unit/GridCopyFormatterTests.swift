import Foundation
import XCTest
@testable import TableLite

/// 复制格式的纯函数边界。见 specs/03-data-browsing.md §9、docs/tech-designs/07-data-grid.md §8。
final class GridCopyFormatterTests: XCTestCase {

    // MARK: - Fixtures

    private func textColumn(_ name: String) -> TableColumn {
        TableColumn(name: name, dataType: "varchar", rawTypeText: "varchar(255)", kind: .text)
    }

    private func intColumn(_ name: String) -> TableColumn {
        TableColumn(name: name, dataType: "int", rawTypeText: "int", kind: .integer(isUnsigned: false))
    }

    private func boolColumn(_ name: String) -> TableColumn {
        TableColumn(name: name, dataType: "tinyint", rawTypeText: "tinyint(1)", kind: .boolean)
    }

    private func blobColumn(_ name: String) -> TableColumn {
        TableColumn(name: name, dataType: "blob", rawTypeText: "blob", kind: .blob)
    }

    private func largeTextColumn(_ name: String) -> TableColumn {
        TableColumn(name: name, dataType: "longtext", rawTypeText: "longtext", kind: .text)
    }

    private func row(_ values: CellValue..., truncated: [String: Int] = [:]) -> TableDataRow {
        TableDataRow(identity: .existing(UUID().uuidString), values: values, truncatedLengths: truncated)
    }

    private let ref = TableRef(database: "app", table: "users")

    // MARK: - JSON

    func testJSONNullBecomesNullLiteral() {
        let column = textColumn("name")
        XCTAssertEqual(GridCopyFormatter.jsonValue(.null, column: column), "null")
    }

    func testJSONNumericKindEmitsRawNumber() {
        XCTAssertEqual(GridCopyFormatter.jsonValue(.text("42"), column: intColumn("id")), "42")
        XCTAssertEqual(GridCopyFormatter.jsonValue(.text("-3.5"), column: intColumn("id")), "-3.5")
    }

    func testJSONNumericKindFallsBackToStringWhenNotNumeric() {
        XCTAssertEqual(GridCopyFormatter.jsonValue(.text("1e5"), column: intColumn("id")), "\"1e5\"")
        XCTAssertEqual(GridCopyFormatter.jsonValue(.text("abc"), column: intColumn("id")), "\"abc\"")
    }

    func testJSONBooleanEmitsTrueFalse() {
        XCTAssertEqual(GridCopyFormatter.jsonValue(.text("1"), column: boolColumn("flag")), "true")
        XCTAssertEqual(GridCopyFormatter.jsonValue(.text("0"), column: boolColumn("flag")), "false")
    }

    func testJSONStringEscapesQuotesBackslashAndNewlines() {
        XCTAssertEqual(GridCopyFormatter.jsonString("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(GridCopyFormatter.jsonString("a\nb\tc"), "\"a\\nb\\tc\"")
        XCTAssertEqual(GridCopyFormatter.jsonString("\u{01}"), "\"\\u0001\"")
    }

    func testJSONBinaryBecomesHexString() {
        let value = CellValue.bytes([0xDE, 0xAD])
        XCTAssertEqual(GridCopyFormatter.jsonValue(value, column: blobColumn("data")), "\"0xDEAD\"")
    }

    func testJSONArrayUsesColumnNamesAsKeys() {
        let columns = [intColumn("id"), textColumn("name")]
        let rows = [row(.text("1"), .text("张三")), row(.text("2"), .null)]
        let json = GridCopyFormatter.json(rows, columns: columns)
        XCTAssertTrue(json.hasPrefix("[\n"))
        XCTAssertTrue(json.contains("\"id\": 1"))
        XCTAssertTrue(json.contains("\"name\": \"张三\""))
        XCTAssertTrue(json.contains("\"name\": null"))
    }

    // MARK: - Markdown

    func testMarkdownHasHeaderAndSeparator() {
        let columns = [intColumn("id"), textColumn("name")]
        let rows = [row(.text("1"), .text("张三"))]
        let markdown = GridCopyFormatter.markdown(rows, columns: columns, nullText: "NULL")
        XCTAssertEqual(markdown,
                       "| id | name |\n"
                       + "| --- | --- |\n"
                       + "| 1 | 张三 |")
    }

    func testMarkdownEscapesPipeAndNewline() {
        XCTAssertEqual(GridCopyFormatter.markdownCell("a|b"), "a\\|b")
        XCTAssertEqual(GridCopyFormatter.markdownCell("a\nb"), "a<br>b")
    }

    func testMarkdownNullUsesNullText() {
        let columns = [textColumn("name")]
        let rows = [row(.null)]
        let markdown = GridCopyFormatter.markdown(rows, columns: columns, nullText: "NULL")
        XCTAssertTrue(markdown.hasSuffix("| NULL |"))
    }

    // MARK: - CSV

    func testCSVIncludeHeaderAndQuotes() {
        let columns = [textColumn("name"), textColumn("note")]
        let rows = [row(.text("张三"), .text("a,b"))]
        let csv = GridCopyFormatter.csv(rows, columns: columns, delimiter: ",",
                                        includeHeader: true, nullStyle: .empty)
        XCTAssertEqual(csv, "name,note\n张三,\"a,b\"")
    }

    func testCSVWithoutHeader() {
        let columns = [textColumn("name")]
        let rows = [row(.text("张三"))]
        let csv = GridCopyFormatter.csv(rows, columns: columns, delimiter: ",",
                                        includeHeader: false, nullStyle: .empty)
        XCTAssertEqual(csv, "张三")
    }

    func testCSVNullStyles() {
        let columns = [textColumn("name")]
        let rows = [row(.null)]
        XCTAssertEqual(GridCopyFormatter.csv(rows, columns: columns, delimiter: ",",
                                             includeHeader: false, nullStyle: .empty), "")
        XCTAssertEqual(GridCopyFormatter.csv(rows, columns: columns, delimiter: ",",
                                             includeHeader: false, nullStyle: .literalNULL), "NULL")
    }

    func testCSVBinaryBecomesHex() {
        let columns = [blobColumn("data")]
        let rows = [row(.bytes([0x00, 0xAB]))]
        let csv = GridCopyFormatter.csv(rows, columns: columns, delimiter: ",",
                                        includeHeader: false, nullStyle: .empty)
        XCTAssertEqual(csv, "0x00AB")
    }

    func testCSVTabDelimiter() {
        let columns = [textColumn("a"), textColumn("b")]
        let rows = [row(.text("x"), .text("y"))]
        let csv = GridCopyFormatter.csv(rows, columns: columns, delimiter: "\t",
                                        includeHeader: false, nullStyle: .empty)
        XCTAssertEqual(csv, "x\ty")
    }

    // MARK: - SQL INSERT

    func testSQLInsertEscapesTextAndQuotesIdentifiers() {
        let columns = [textColumn("name")]
        let rows = [row(.text("O'Brien"))]
        let sql = GridCopyFormatter.sqlInsert(ref: ref, rows: rows, columns: columns,
                                              using: .conservative)
        XCTAssertEqual(sql, "INSERT INTO `app`.`users` (`name`) VALUES ('O\\'Brien');")
    }

    func testSQLInsertNumericUnquotedAndNull() {
        let columns = [intColumn("id"), textColumn("name")]
        let rows = [row(.text("42"), .null)]
        let sql = GridCopyFormatter.sqlInsert(ref: ref, rows: rows, columns: columns,
                                              using: .conservative)
        XCTAssertEqual(sql, "INSERT INTO `app`.`users` (`id`, `name`) VALUES (42, NULL);")
    }

    func testSQLInsertBinaryHex() {
        let columns = [blobColumn("data")]
        let rows = [row(.bytes([0xDE, 0xAD]))]
        let sql = GridCopyFormatter.sqlInsert(ref: ref, rows: rows, columns: columns,
                                              using: .conservative)
        XCTAssertEqual(sql, "INSERT INTO `app`.`users` (`data`) VALUES (0xDEAD);")
    }

    func testSQLInsertSkipsTruncatedLargeColumns() {
        let columns = [intColumn("id"), largeTextColumn("content")]
        let rows = [row(.text("1"), .text("prefix"), truncated: ["content": 5000])]
        let sql = GridCopyFormatter.sqlInsert(ref: ref, rows: rows, columns: columns,
                                              using: .conservative)
        XCTAssertEqual(sql, "INSERT INTO `app`.`users` (`id`) VALUES (1);")
    }

    func testSQLInsertMultipleRows() {
        let columns = [intColumn("id")]
        let rows = [row(.text("1")), row(.text("2"))]
        let sql = GridCopyFormatter.sqlInsert(ref: ref, rows: rows, columns: columns,
                                              using: .conservative)
        XCTAssertEqual(sql,
                       "INSERT INTO `app`.`users` (`id`) VALUES (1);\n"
                       + "INSERT INTO `app`.`users` (`id`) VALUES (2);")
    }

    // MARK: - 文本 / 列

    func testCellTextNullAndBinary() {
        XCTAssertEqual(GridCopyFormatter.cellText(.null, column: textColumn("c"), nullText: "NULL"), "NULL")
        XCTAssertEqual(GridCopyFormatter.cellText(.bytes([0xAB]), column: blobColumn("c"), nullText: "NULL"),
                       "0xAB")
        XCTAssertEqual(GridCopyFormatter.cellText(.text("hi"), column: textColumn("c"), nullText: "NULL"), "hi")
    }

    func testColumnNamesCommaSeparated() {
        XCTAssertEqual(GridCopyFormatter.columnNames([textColumn("id"), textColumn("name")]), "id, name")
    }

    func testColumnTextOneValuePerLine() {
        let rows = [row(.text("1")), row(.null), row(.text("3"))]
        let text = GridCopyFormatter.columnText(rows, column: intColumn("id"), index: 0, nullText: "NULL")
        XCTAssertEqual(text, "1\nNULL\n3")
    }

    func testRowTextTabSeparated() {
        let columns = [intColumn("id"), textColumn("name")]
        let text = GridCopyFormatter.rowText(row(.text("1"), .null), columns: columns, nullText: "NULL")
        XCTAssertEqual(text, "1\tNULL")
    }

    // MARK: - 建表语句

    func testCreateStatementTrimsWhitespace() {
        let structure = TableStructure(ref: ref, kind: .table, comment: nil, columns: [],
                                       indexes: [], foreignKeys: [], triggers: [],
                                       createStatement: "\nCREATE TABLE `t` (...);\n")
        XCTAssertEqual(GridCopyFormatter.createStatement(structure), "CREATE TABLE `t` (...);")
    }

    // MARK: - GridValueFormatter

    func testByteCountFormatting() {
        XCTAssertEqual(GridValueFormatter.byteCount(25), "25 B")
        XCTAssertEqual(GridValueFormatter.byteCount(12_600), "12.3 KB")
        XCTAssertEqual(GridValueFormatter.byteCount(2_200_000), "2.1 MB")
    }

    func testImageFormatDetection() {
        XCTAssertEqual(GridValueFormatter.imageFormat([0x89, 0x50, 0x4E, 0x47, 0x00]), "PNG")
        XCTAssertEqual(GridValueFormatter.imageFormat([0xFF, 0xD8, 0xFF, 0x00]), "JPEG")
        XCTAssertEqual(GridValueFormatter.imageFormat([0x4D, 0x4D, 0x00, 0x2A]), "TIFF")
        XCTAssertNil(GridValueFormatter.imageFormat([0x00, 0x01, 0x02]))
    }

    func testBinaryPlaceholderImageAndGeometry() {
        let png = [UInt8](repeating: 0, count: 1024)
        var withHeader = png
        withHeader[0] = 0x89; withHeader[1] = 0x50; withHeader[2] = 0x4E; withHeader[3] = 0x47
        XCTAssertEqual(GridValueFormatter.binaryPlaceholder(kind: .blob, bytes: withHeader),
                       "«图片 PNG 1.0 KB»")
        XCTAssertEqual(GridValueFormatter.binaryPlaceholder(kind: .geometry, bytes: [UInt8](repeating: 0, count: 25)),
                       "«GEOMETRY 25 B»")
    }

    func testBinaryPlaceholderShortHexAndLargeBlob() {
        XCTAssertEqual(GridValueFormatter.binaryPlaceholder(kind: .blob, bytes: [0xDE, 0xAD]), "0xDEAD")
        let big = [UInt8](repeating: 0x41, count: 4096)
        XCTAssertEqual(GridValueFormatter.binaryPlaceholder(kind: .blob, bytes: big), "«BLOB 4.0 KB»")
    }
}
