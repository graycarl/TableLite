import XCTest
@testable import TableLite

/// Console Log 记录累计的纯逻辑：实际行数、影响行数、错误码。
/// 见 docs/tech-designs/02-persistence.md §5、docs/tech-designs/10-query-editor.md §8。
final class QueryLogRecordTests: XCTestCase {

    // MARK: 辅助

    private func row() -> QueryEvent {
        .row(resultIndex: 0, rowIndex: 0, values: [.text("v")])
    }

    private func okHeader(affectedRows: UInt64) -> ResultSetHeader {
        ResultSetHeader(index: 0, columns: [], affectedRows: affectedRows, lastInsertID: 0)
    }

    private func resultSetHeader() -> ResultSetHeader {
        ResultSetHeader(index: 0,
                        columns: [ResultSetColumn(name: "id",
                                                  originalTable: nil,
                                                  originalColumn: nil,
                                                  database: nil,
                                                  fieldType: 3,
                                                  flags: 0,
                                                  charsetNumber: 63,
                                                  length: 11,
                                                  decimals: 0,
                                                  kind: .integer(isUnsigned: false),
                                                  isBinary: false,
                                                  isNotNull: false,
                                                  isPrimaryKey: false,
                                                  isUnsigned: false,
                                                  isAutoIncrement: false)],
                        affectedRows: 0,
                        lastInsertID: 0)
    }

    // MARK: 行数 / 影响行数

    func testCountsStreamedRows() {
        var accumulator = QueryLogAccumulator()
        accumulator.observe(.resultSet(resultSetHeader()))
        accumulator.observe(row())
        accumulator.observe(row())
        accumulator.observe(.finished)

        XCTAssertEqual(accumulator.rowCount, 2)
        XCTAssertNil(accumulator.affectedRows)
        XCTAssertNil(accumulator.errorCode)
    }

    func testCapturesAffectedRowsFromOKPacket() {
        var accumulator = QueryLogAccumulator()
        accumulator.observe(.resultSet(okHeader(affectedRows: 3)))

        XCTAssertEqual(accumulator.rowCount, 0)
        XCTAssertEqual(accumulator.affectedRows, 3)
        XCTAssertNil(accumulator.errorCode)
    }

    // MARK: 错误

    func testCapturesFirstStatementError() {
        var accumulator = QueryLogAccumulator()
        accumulator.observe(.statementError(resultIndex: 0,
                                            error: MySQLServerError(code: 1064,
                                                                    sqlState: "42000",
                                                                    message: "语法错误",
                                                                    sql: "SELECT")))
        accumulator.observe(.statementError(resultIndex: 1,
                                            error: MySQLServerError(code: 1146,
                                                                    sqlState: "42S02",
                                                                    message: "表不存在",
                                                                    sql: "SELECT")))

        XCTAssertEqual(accumulator.errorCode, 1064)
        XCTAssertEqual(accumulator.errorMessage, "语法错误")
    }

    func testThrownCancellationUsesSyntheticCode() {
        var accumulator = QueryLogAccumulator()
        accumulator.observe(thrown: MySQLError.cancelled)

        XCTAssertEqual(accumulator.errorCode, 1317)
        XCTAssertEqual(accumulator.errorMessage, "查询已取消")
    }

    func testThrownServerErrorKeepsServerCode() {
        var accumulator = QueryLogAccumulator()
        accumulator.observe(thrown: MySQLError.server(MySQLServerError(code: 1049,
                                                                       sqlState: "42000",
                                                                       message: "未知数据库",
                                                                       sql: nil)))

        XCTAssertEqual(accumulator.errorCode, 1049)
        XCTAssertEqual(accumulator.errorMessage, "未知数据库")
    }

    func testStatementErrorWinsOverThrownError() {
        var accumulator = QueryLogAccumulator()
        accumulator.observe(.statementError(resultIndex: 0,
                                            error: MySQLServerError(code: 1064,
                                                                    sqlState: "42000",
                                                                    message: "语法错误",
                                                                    sql: nil)))
        accumulator.observe(thrown: MySQLError.connectionLost(nil))

        XCTAssertEqual(accumulator.errorCode, 1064)
        XCTAssertEqual(accumulator.errorMessage, "语法错误")
    }

    // MARK: 记录构造

    func testRecordBuildsAllFields() {
        var accumulator = QueryLogAccumulator()
        accumulator.observe(row())
        accumulator.observe(.finished)

        let record = accumulator.record(sql: "SELECT 1",
                                        category: .data,
                                        database: "app_dev",
                                        elapsed: .milliseconds(42))

        XCTAssertEqual(record.sql, "SELECT 1")
        XCTAssertEqual(record.category, .data)
        XCTAssertEqual(record.database, "app_dev")
        XCTAssertEqual(record.elapsed, .milliseconds(42))
        XCTAssertEqual(record.rowCount, 1)
        XCTAssertNil(record.affectedRows)
        XCTAssertNil(record.errorCode)
    }
}
