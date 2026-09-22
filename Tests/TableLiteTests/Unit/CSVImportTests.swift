import XCTest
@testable import TableLite

/// 导入：类型推断、列映射、分批 INSERT、失败行报告、字面量转换。
///
/// 见 `specs/08-import-export.md` §2、`docs/tech-designs/11-schema-and-import-export.md` §4。
final class CSVImportTests: XCTestCase {

    // MARK: - 类型推断

    func testInferColumnTypes() {
        let inferences = CSVTypeInference.infer(
            header: ["id", "name", "amount", "created_at"],
            rows: [
                ["1", "张三", "12.50", "2025-01-01 10:00:00"],
                ["2", "李四", "3.25", "2025-01-02 11:30:00"],
                ["3", "王五", "0.99", "2025-01-03T09:30:00"],
            ]
        )
        XCTAssertEqual(inferences.map(\.type), [.int, .varchar, .decimal, .dateTime])
        XCTAssertEqual(inferences.map(\.name), ["id", "name", "amount", "created_at"])
    }

    func testInferBigIntWhenOutOfInt32Range() {
        let inferences = CSVTypeInference.infer(
            header: ["n"],
            rows: [["1"], ["4000000000"]]
        )
        XCTAssertEqual(inferences.first?.type, .bigint)
        XCTAssertEqual(inferences.first?.reason, "整数超出 INT 范围")
    }

    func testInferEmptyColumnAsVarchar() {
        let inferences = CSVTypeInference.infer(header: ["a", "b"], rows: [["", "x"]])
        XCTAssertEqual(inferences.first?.type, .varchar)
        XCTAssertEqual(inferences.first?.reason, "空列，按文本")
    }

    func testColumnNamesFallBackForEmptyAndDuplicateHeader() {
        let names = CSVTypeInference.columnNames(header: ["id", "", "id"], columnCount: 3)
        XCTAssertEqual(names, ["id", "col_2", "col_3"])
    }

    func testColumnNamesWithoutHeader() {
        XCTAssertEqual(
            CSVTypeInference.columnNames(header: nil, columnCount: 2),
            ["col_1", "col_2"]
        )
    }

    // MARK: - 列映射

    private var targetColumns: [ColumnInfo] {
        [
            TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63),
            TestSupport.column("name", type: .varString, flags: ColumnFlag.notNull),
            TestSupport.column("email", type: .varString),
        ]
    }

    func testAutoMapMatchesByNameAndSkipsUnmatched() {
        let mappings = ImportColumnMapper.autoMap(
            csvColumns: ["ID", "name", "phone"],
            targetColumns: targetColumns
        )
        XCTAssertEqual(mappings[0].targetColumn, "id")
        XCTAssertEqual(mappings[0].note, "主键")
        XCTAssertEqual(mappings[1].targetColumn, "name")
        XCTAssertEqual(mappings[1].note, "非空")
        XCTAssertNil(mappings[2].targetColumn)
        XCTAssertEqual(mappings[2].note, "未匹配到")
    }

    func testAutoMapDoesNotAssignSameTargetTwice() {
        let mappings = ImportColumnMapper.autoMap(
            csvColumns: ["name", "name"],
            targetColumns: targetColumns
        )
        XCTAssertEqual(mappings[0].targetColumn, "name")
        XCTAssertNil(mappings[1].targetColumn)
    }

    func testUnmappedRequiredColumns() {
        let mappings = ImportColumnMapper.autoMap(
            csvColumns: ["id", "email"],
            targetColumns: targetColumns
        )
        let missing = ImportColumnMapper.unmappedRequiredColumns(
            mappings: mappings,
            targetColumns: targetColumns
        )
        XCTAssertEqual(missing.map(\.name), ["name"])
    }

    // MARK: - 分批 INSERT

    func testInsertBatchesSplitByBatchSize() {
        let options = ImportOptions()
        var configured = options
        configured.batchSize = 2
        let rows = [
            ImportRow(fields: ["1", "a"], lineNumber: 2),
            ImportRow(fields: ["2", "b"], lineNumber: 3),
            ImportRow(fields: ["3", "c"], lineNumber: 4),
        ]
        let batches = CSVImportStatementBuilder.insertBatches(
            database: "app_dev",
            table: "users",
            columns: [targetColumns[0], targetColumns[1]],
            rows: rows,
            options: configured
        )
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].rows.count, 2)
        XCTAssertEqual(batches[1].rows.count, 1)
        XCTAssertEqual(batches[1].firstLineNumber, 4)
    }

    func testInsertStatementEscapesValuesAndUsesNull() {
        let options = ImportOptions()
        let sql = CSVImportStatementBuilder.insertStatement(
            database: "app_dev",
            table: "users",
            columns: [targetColumns[0], targetColumns[1]],
            rows: [
                ImportRow(fields: ["1", "a'b"], lineNumber: 2),
                ImportRow(fields: ["2", ""], lineNumber: 3),
            ],
            options: options
        )
        XCTAssertTrue(sql.hasPrefix("INSERT INTO `app_dev`.`users` (`id`, `name`) VALUES "))
        XCTAssertTrue(sql.contains("(1, 'a\\'b')"))
        XCTAssertTrue(sql.contains("(2, NULL)"))
    }

    func testInsertStatementKeepsEmptyStringWhenConfigured() {
        var options = ImportOptions()
        options.emptyFieldIsNull = false
        let sql = CSVImportStatementBuilder.insertStatement(
            database: "app_dev",
            table: "users",
            columns: [targetColumns[1]],
            rows: [ImportRow(fields: [""], lineNumber: 2)],
            options: options
        )
        XCTAssertTrue(sql.contains("('')"))
    }

    func testCreateTableStatement() {
        let sql = CSVImportStatementBuilder.createTableStatement(
            database: "app_dev",
            tableName: "users_imported",
            columns: [
                CSVColumnInference(name: "id", type: .int, reason: "全是整数"),
                CSVColumnInference(name: "name", type: .varchar, reason: "文本"),
                CSVColumnInference(name: "created_at", type: .dateTime, reason: "形如日期时间"),
            ]
        )
        XCTAssertEqual(
            sql,
            "CREATE TABLE `app_dev`.`users_imported` (\n  `id` INT,\n  `name` VARCHAR(255),\n  `created_at` DATETIME\n);"
        )
    }

    // MARK: - 失败行报告

    func testFailureReportCSV() {
        let csv = ImportFailureReport.csv(failures: [
            ImportFailure(
                lineNumber: 1204,
                fields: ["x,y", "z"],
                message: "[错误 1406] Data too long for column 'name'"
            ),
        ])
        XCTAssertTrue(csv.hasPrefix("行号,错误,原始内容\n"))
        XCTAssertTrue(csv.contains("1204"))
        XCTAssertTrue(csv.contains("\"x,y,z\""))
        XCTAssertTrue(csv.contains("Data too long"))
    }

    // MARK: - 字段 → SQLValue

    func testHexDataRoundTrip() {
        XCTAssertEqual(ImportValueConversion.hexData("0xDEAD"), Data([0xDE, 0xAD]))
        XCTAssertEqual(ImportValueConversion.hexData("X'DEAD'"), Data([0xDE, 0xAD]))
        XCTAssertNil(ImportValueConversion.hexData("DEAD"))
        XCTAssertNil(ImportValueConversion.hexData("0xZZ"))
    }

    func testValueConversionTreatsEmptyAsNullByDefault() {
        let tableColumn = ColumnInfo(name: "n", fieldType: .long)
        XCTAssertEqual(ImportValueConversion.value(from: "", column: tableColumn, emptyIsNull: true), .null)
        XCTAssertEqual(ImportValueConversion.value(from: "", column: tableColumn, emptyIsNull: false), .text(""))
        XCTAssertEqual(ImportValueConversion.value(from: "42", column: tableColumn, emptyIsNull: true), .text("42"))
    }

    // MARK: - 目标列工厂

    func testNewTableColumnFactoryMapsNumericTypes() {
        XCTAssertTrue(ImportNewTableColumnFactory.columnInfo(name: "id", type: .int).fieldType.isNumeric)
        XCTAssertEqual(ImportNewTableColumnFactory.columnInfo(name: "t", type: .text).isBinary, false)
    }
}
