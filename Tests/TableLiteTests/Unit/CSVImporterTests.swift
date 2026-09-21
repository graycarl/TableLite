import Foundation
import XCTest
@testable import TableLite

/// 导入：列推断 / 建表 / 批量 INSERT / 类型校验。
/// 见 docs/tech-designs/11-schema-and-import-export.md §4、specs/08-import-export.md §2。
final class CSVImporterTests: XCTestCase {

    private let literalizer = SQLValueLiteralizer.conservative

    private func tableColumn(_ name: String,
                             kind: ColumnKind,
                             nullable: Bool = true) -> TableColumn {
        TableColumn(name: name, dataType: "int", rawTypeText: "int",
                    isNullable: nullable, kind: kind)
    }

    // MARK: - 类型推断

    func testInferColumnsInteger() {
        let result = CSVImporter.inferColumns(rows: [["id"], ["1"], ["2"]],
                                              hasHeader: true, sampleLimit: 10)
        XCTAssertEqual(result, [CSVImporter.TypeInference(columnName: "id", inferredType: "int")])
    }

    func testInferColumnsBigint() {
        let result = CSVImporter.inferColumns(rows: [["n"], ["9999999999"]],
                                              hasHeader: true, sampleLimit: 10)
        XCTAssertEqual(result.first?.inferredType, "bigint")
    }

    func testInferColumnsDecimal() {
        let result = CSVImporter.inferColumns(rows: [["p"], ["1.5"], ["2.25"]],
                                              hasHeader: true, sampleLimit: 10)
        XCTAssertEqual(result.first?.inferredType, "decimal(20,6)")
    }

    func testInferColumnsDateTime() {
        let result = CSVImporter.inferColumns(rows: [["t"], ["2024-01-01 10:00:00"]],
                                              hasHeader: true, sampleLimit: 10)
        XCTAssertEqual(result.first?.inferredType, "datetime")
    }

    func testInferColumnsText() {
        let result = CSVImporter.inferColumns(rows: [["s"], ["hello"]],
                                              hasHeader: true, sampleLimit: 10)
        XCTAssertEqual(result.first?.inferredType, "varchar(255)")
    }

    func testInferColumnsLongTextBecomesText() {
        let long = String(repeating: "x", count: 300)
        let result = CSVImporter.inferColumns(rows: [["s"], [long]],
                                              hasHeader: true, sampleLimit: 10)
        XCTAssertEqual(result.first?.inferredType, "text")
    }

    func testInferColumnsEmptyHeaderAndDuplicateUseColN() {
        let rows = [["", "id", "id"], ["1", "2", "3"]]
        let result = CSVImporter.inferColumns(rows: rows, hasHeader: true, sampleLimit: 10)
        XCTAssertEqual(result.map(\.columnName), ["col_1", "id", "col_3"])
    }

    func testInferColumnsWithoutHeader() {
        let result = CSVImporter.inferColumns(rows: [["1", "a"], ["2", "b"]],
                                              hasHeader: false, sampleLimit: 10)
        XCTAssertEqual(result.map(\.columnName), ["col_1", "col_2"])
        XCTAssertEqual(result.map(\.inferredType), ["int", "varchar(255)"])
    }

    // MARK: - CREATE TABLE

    func testCreateTableSQLQuotesIdentifiers() {
        let columns = [
            CSVImporter.TypeInference(columnName: "id", inferredType: "int"),
            CSVImporter.TypeInference(columnName: "name", inferredType: "varchar(255)")
        ]
        let sql = CSVImporter.createTableSQL(table: "users", database: "app_dev",
                                             columns: columns, fallbackToText: false)
        XCTAssertTrue(sql.contains("CREATE TABLE `app_dev`.`users` ("))
        XCTAssertTrue(sql.contains("`id` int"))
        XCTAssertTrue(sql.contains("`name` varchar(255)"))
    }

    func testCreateTableSQLFallbackToText() {
        let columns = [CSVImporter.TypeInference(columnName: "id", inferredType: "int")]
        let sql = CSVImporter.createTableSQL(table: "t", database: "d",
                                             columns: columns, fallbackToText: true)
        XCTAssertTrue(sql.contains("`id` text"))
    }

    // MARK: - 批量 INSERT

    func testInsertBatchesRespectsMappingAndSkips() {
        let table = TableRef(database: "db", table: "t")
        let columns = [tableColumn("id", kind: .integer(isUnsigned: false)),
                       tableColumn("name", kind: .text)]
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: "id"),
                       CSVImporter.ColumnMapping(sourceIndex: 1, targetColumn: nil),
                       CSVImporter.ColumnMapping(sourceIndex: 2, targetColumn: "name")]
        let statements = CSVImporter.insertBatches(
            table: table, targetColumns: columns, mapping: mapping,
            rows: [["1", "skip", "alice"]],
            literalizer: literalizer, batchSize: 500)
        XCTAssertEqual(statements, ["INSERT INTO `db`.`t` (`id`, `name`) VALUES (1, 'alice')"])
    }

    func testInsertBatchesSplitsByBatchSize() {
        let table = TableRef(database: "db", table: "t")
        let columns = [tableColumn("id", kind: .integer(isUnsigned: false))]
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: "id")]
        let rows = (0..<1200).map { ["\($0)"] }
        let statements = CSVImporter.insertBatches(
            table: table, targetColumns: columns, mapping: mapping,
            rows: rows, literalizer: literalizer, batchSize: 500)
        XCTAssertEqual(statements.count, 3)
        let tupleCounts = statements.map { statement -> Int in
            let body = statement.components(separatedBy: " VALUES ").last ?? ""
            return body.components(separatedBy: "), (").count
        }
        XCTAssertEqual(tupleCounts, [500, 500, 200])
    }

    func testInsertBatchesEscapesAndNulls() {
        let table = TableRef(database: "db", table: "t")
        let columns = [tableColumn("name", kind: .text)]
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: "name")]
        let statements = CSVImporter.insertBatches(
            table: table, targetColumns: columns, mapping: mapping,
            rows: [["O'Brien"], [""]],
            literalizer: literalizer, batchSize: 500)
        XCTAssertEqual(statements,
                       ["INSERT INTO `db`.`t` (`name`) VALUES ('O\\'Brien'), (NULL)"])
    }

    func testInsertBatchesEmptyWhenNothingMapped() {
        let table = TableRef(database: "db", table: "t")
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: nil)]
        let statements = CSVImporter.insertBatches(
            table: table, targetColumns: [], mapping: mapping,
            rows: [["x"]], literalizer: literalizer, batchSize: 500)
        XCTAssertTrue(statements.isEmpty)
    }

    // MARK: - 校验

    func testValidateRejectsBadInteger() {
        let columns = [tableColumn("id", kind: .integer(isUnsigned: false))]
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: "id")]
        let failures = CSVImporter.validate(rows: [["1"], ["abc"]],
                                            mapping: mapping, targetColumns: columns)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.rowNumber, 2)
        XCTAssertEqual(failures.first?.content, ["abc"])
        XCTAssertEqual(failures.first?.message, "列 id 不是合法整数")
    }

    func testValidateRejectsBadDateTime() {
        let columns = [tableColumn("t", kind: .dateTime)]
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: "t")]
        let failures = CSVImporter.validate(rows: [["2024-01-01 10:00:00"], ["nope"]],
                                            mapping: mapping, targetColumns: columns)
        XCTAssertEqual(failures.map(\.rowNumber), [2])
    }

    func testValidateEmptyOnNotNullColumn() {
        let columns = [tableColumn("id", kind: .integer(isUnsigned: false), nullable: false)]
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: "id")]
        let failures = CSVImporter.validate(rows: [[""]],
                                            mapping: mapping, targetColumns: columns)
        XCTAssertEqual(failures.first?.message, "列 id 不允许为空")
    }

    func testValidateLimitsToFirstHundred() {
        let columns = [tableColumn("id", kind: .integer(isUnsigned: false))]
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: "id")]
        let rows = (0..<150).map { _ in ["bad"] }
        let failures = CSVImporter.validate(rows: rows, mapping: mapping, targetColumns: columns)
        XCTAssertEqual(failures.count, 100)
    }

    func testValidateIgnoresSkippedAndUnknownColumns() {
        let columns = [tableColumn("id", kind: .integer(isUnsigned: false))]
        let mapping = [CSVImporter.ColumnMapping(sourceIndex: 0, targetColumn: "other")]
        let failures = CSVImporter.validate(rows: [["abc"]], mapping: mapping, targetColumns: columns)
        XCTAssertTrue(failures.isEmpty)
    }
}
