import XCTest
@testable import TableLite

/// 查询标签的纯逻辑：光标选语句、状态栏文案、错误合成。
/// 见 docs/tech-designs/10-query-editor.md §5、specs/06-query-editor.md §3。
final class QueryTabLogicTests: XCTestCase {

    // MARK: 光标所在语句

    func testStatementIndexAtCursor() {
        let sql = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        let statements = StatementSplitter.split(sql)
        XCTAssertEqual(statements.count, 3)

        XCTAssertEqual(QueryTabLogic.statementIndex(atCursor: 2, in: statements), 0)
        let second = statements[1].range.location
        XCTAssertEqual(QueryTabLogic.statementIndex(atCursor: second + 1, in: statements), 1)
        let third = statements[2].range.location
        XCTAssertEqual(QueryTabLogic.statementIndex(atCursor: third, in: statements), 2)
    }

    func testStatementIndexClampsToLastForTrailingLocation() {
        let statements = StatementSplitter.split("SELECT 1;")
        let length = (("SELECT 1;") as NSString).length
        XCTAssertEqual(QueryTabLogic.statementIndex(atCursor: length + 10, in: statements), 0)
    }

    func testStatementIndexWithoutSemicolon() {
        let statements = StatementSplitter.split("SELECT 1\nSELECT 2")
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(QueryTabLogic.statementIndex(atCursor: 0, in: statements), 0)
    }

    func testStatementIndexEmpty() {
        XCTAssertNil(QueryTabLogic.statementIndex(atCursor: 0, in: []))
    }

    // MARK: 状态栏文案

    func testStatusSummary() {
        let results = [
            rowsResult(id: 0, rows: 1000, elapsed: .milliseconds(20)),
            rowsResult(id: 1, rows: 204, elapsed: .milliseconds(22)),
            QueryResult(id: 2,
                        statement: "UPDATE t SET a = 1",
                        kind: .affected(ResultSetHeader(index: 0, columns: [], affectedRows: 5, lastInsertID: 0)),
                        elapsed: .zero,
                        title: QueryResult.completedTitle),
            QueryResult(id: 3,
                        statement: "DROP TABLE t",
                        kind: .rejected("只读模式：写操作已被禁用"),
                        elapsed: .zero,
                        title: QueryResult.rejectedTitle),
        ]
        XCTAssertEqual(QueryTabLogic.statusSummary(for: results),
                       "已执行 3 条语句 · 耗时 42 ms · 返回 1,204 行 · 只读拦截 1 条")
    }

    func testStatusSummaryAffectedOnly() {
        let results = [
            QueryResult(id: 0,
                        statement: "UPDATE t SET a = 1",
                        kind: .affected(ResultSetHeader(index: 0, columns: [], affectedRows: 3, lastInsertID: 0)),
                        elapsed: .milliseconds(12),
                        title: QueryResult.completedTitle),
        ]
        XCTAssertEqual(QueryTabLogic.statusSummary(for: results),
                       "已执行 1 条语句 · 耗时 12 ms · 影响 3 行")
    }

    func testStatusSummaryEmpty() {
        XCTAssertEqual(QueryTabLogic.statusSummary(for: []), "就绪")
    }

    // MARK: 数字 / 耗时格式化

    func testGrouped() {
        XCTAssertEqual(QueryTabLogic.grouped(0), "0")
        XCTAssertEqual(QueryTabLogic.grouped(5), "5")
        XCTAssertEqual(QueryTabLogic.grouped(999), "999")
        XCTAssertEqual(QueryTabLogic.grouped(1000), "1,000")
        XCTAssertEqual(QueryTabLogic.grouped(1204), "1,204")
        XCTAssertEqual(QueryTabLogic.grouped(1234567), "1,234,567")
        XCTAssertEqual(QueryTabLogic.grouped(-1204), "-1,204")
    }

    func testElapsedText() {
        XCTAssertEqual(QueryTabLogic.elapsedText(.zero), "<1 ms")
        XCTAssertEqual(QueryTabLogic.elapsedText(.milliseconds(42)), "42 ms")
        XCTAssertEqual(QueryTabLogic.elapsedText(.milliseconds(1500)), "1,500 ms")
    }

    // MARK: 错误合成

    func testSyntheticErrorForCancellation() {
        let error = QueryTabLogic.syntheticError(for: .cancelled)
        XCTAssertEqual(error.code, 1317)
        XCTAssertTrue(error.isCancelled)
    }

    func testSyntheticErrorForTimeout() {
        let error = QueryTabLogic.syntheticError(for: .timeout)
        XCTAssertEqual(error.message, "查询超时")
    }

    func testSyntheticErrorForConnectionLostKeepsServerError() {
        let serverError = MySQLServerError(code: 2013, sqlState: "HY000", message: "Lost connection", sql: nil)
        XCTAssertEqual(QueryTabLogic.syntheticError(for: .connectionLost(serverError)), serverError)
    }

    // MARK: 辅助

    private func rowsResult(id: Int, rows: Int, elapsed: Duration) -> QueryResult {
        let header = ResultSetHeader(index: 0, columns: [], affectedRows: 0, lastInsertID: 0)
        let values = Array(repeating: [CellValue.null], count: rows)
        return QueryResult(id: id,
                           statement: "SELECT 1",
                           kind: .rows(MaterializedResultSet(header: header, rows: values)),
                           elapsed: elapsed,
                           title: QueryResult.rowsTitle(1))
    }
}
