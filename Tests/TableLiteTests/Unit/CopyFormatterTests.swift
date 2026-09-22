import XCTest
@testable import TableLite

/// 复制格式：TSV / JSON / Markdown / CSV / SQL INSERT。
///
/// 见 `docs/tech-designs/07-data-grid.md` §8。
final class CopyFormatterTests: XCTestCase {

    private let columns: [ColumnInfo] = [
        TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63),
        TestSupport.column("name", type: .varString),
        TestSupport.column("active", type: .tiny, charset: 63, length: 1),
    ]

    private let rows: [[SQLValue]] = [
        [.text("1"), .text("张三"), .text("1")],
        [.text("2"), .null, .text("0")],
    ]

    func testCellValue() {
        XCTAssertEqual(
            CopyFormatter.format(rows: [[.text("hello")]], columns: columns, format: .cellValue),
            "hello"
        )
        XCTAssertEqual(
            CopyFormatter.format(rows: [[.null]], columns: columns, format: .cellValue),
            "NULL"
        )
    }

    func testRowAndRowsAreTabSeparated() {
        XCTAssertEqual(
            CopyFormatter.format(rows: rows, columns: columns, format: .row),
            "1\t张三\t1"
        )
        XCTAssertEqual(
            CopyFormatter.format(rows: rows, columns: columns, format: .rows),
            "1\t张三\t1\n2\tNULL\t0"
        )
    }

    func testColumnNamesAndValues() {
        XCTAssertEqual(CopyFormatter.format(rows: rows, columns: columns, format: .columnNames), "id,name,active")
        XCTAssertEqual(CopyFormatter.format(rows: rows, columns: columns, format: .columnValues), "1\n2")
    }

    func testJSONKeepsNumbersUnquotedAndNull() {
        let json = CopyFormatter.format(rows: rows, columns: columns, format: .json)
        XCTAssertEqual(
            json,
            "[{\"id\": 1, \"name\": \"张三\", \"active\": 1}, {\"id\": 2, \"name\": null, \"active\": 0}]"
        )
    }

    func testJSONEscapesAndHexesBinary() {
        let json = CopyFormatter.format(
            rows: [[.text("a\"b"), .binary(Data([0xAB]))]],
            columns: [TestSupport.column("s"), TestSupport.column("blob", type: .blob, charset: 63)],
            format: .json
        )
        XCTAssertEqual(json, "[{\"s\": \"a\\\"b\", \"blob\": \"0xAB\"}]")
    }

    func testMarkdown() {
        let markdown = CopyFormatter.format(rows: rows, columns: columns, format: .markdown)
        XCTAssertEqual(
            markdown,
            "| id | name | active |\n| --- | --- | --- |\n| 1 | 张三 | 1 |\n| 2 | NULL | 0 |"
        )
    }

    func testMarkdownEscapesPipeAndNewline() {
        let markdown = CopyFormatter.format(
            rows: [[.text("a|b"), .text("l1\nl2")]],
            columns: [TestSupport.column("a"), TestSupport.column("b")],
            format: .markdown
        )
        XCTAssertTrue(markdown.contains("a\\|b"))
        XCTAssertTrue(markdown.contains("l1<br>l2"))
    }

    func testCSVWithoutAndWithHeader() {
        XCTAssertEqual(
            CopyFormatter.format(rows: rows, columns: columns, format: .csv),
            "1,张三,1\n2,,0\n"
        )
        XCTAssertEqual(
            CopyFormatter.format(rows: rows, columns: columns, format: .csvWithHeader),
            "id,name,active\n1,张三,1\n2,,0\n"
        )
    }

    func testCSVNullLiteralOption() {
        let text = CopyFormatter.format(
            rows: [[.null]],
            columns: [TestSupport.column("a")],
            format: .csv,
            options: CopyOptions(nullRepresentation: .nullLiteral)
        )
        XCTAssertEqual(text, "NULL\n")
    }

    func testSQLInsert() {
        let sql = CopyFormatter.format(
            rows: rows,
            columns: columns,
            format: .sqlInsert,
            database: "db",
            table: "t"
        )
        XCTAssertEqual(
            sql,
            "INSERT INTO `db`.`t` (`id`, `name`, `active`) VALUES (1, '张三', 1);\n"
                + "INSERT INTO `db`.`t` (`id`, `name`, `active`) VALUES (2, NULL, 0);"
        )
    }

    func testSQLInsertWithoutTableReturnsEmpty() {
        XCTAssertEqual(
            CopyFormatter.format(rows: rows, columns: columns, format: .sqlInsert),
            ""
        )
    }
}
