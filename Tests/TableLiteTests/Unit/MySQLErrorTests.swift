import XCTest
@testable import TableLite

/// MySQL 错误映射：服务器错误码 → 分类 / 中文解释，连接类与执行类必须分开。
///
/// 见 `docs/tech-designs/03-mysql-layer.md` §7、`05-session-management.md` §3/§6。
final class MySQLErrorTests: XCTestCase {

    // MARK: 分类

    func testConnectionClassCodes() {
        XCTAssertEqual(MySQLError.classify(code: 2002), .connectionFailed)
        XCTAssertEqual(MySQLError.classify(code: 2003), .connectionFailed)
        XCTAssertEqual(MySQLError.classify(code: 2005), .connectionFailed)
        XCTAssertEqual(MySQLError.classify(code: 2006), .serverGone)
        XCTAssertEqual(MySQLError.classify(code: 2013), .serverGone)
        XCTAssertEqual(MySQLError.classify(code: 1045), .authentication)
        XCTAssertEqual(MySQLError.classify(code: 1049), .unknownDatabase)
    }

    func testExecutionClassCodes() {
        XCTAssertEqual(MySQLError.classify(code: 1064), .syntax)
        XCTAssertEqual(MySQLError.classify(code: 1142), .permission)
        XCTAssertEqual(MySQLError.classify(code: 1044), .permission)
        XCTAssertEqual(MySQLError.classify(code: 1062), .constraintViolation)
        XCTAssertEqual(MySQLError.classify(code: 1205), .lockWaitTimeout)
        XCTAssertEqual(MySQLError.classify(code: 1213), .deadlock)
        XCTAssertEqual(MySQLError.classify(code: 1146), .unknownTable)
        XCTAssertEqual(MySQLError.classify(code: 1094), .unknownThread)
    }

    func testUnknownCodeFallsBackToServer() {
        XCTAssertEqual(MySQLError.classify(code: 9999), .server)
        XCTAssertEqual(MySQLError.classify(code: 0), .server)
    }

    func testInterruptedCodes() {
        XCTAssertEqual(MySQLError.classify(code: 1317), .interrupted)
        XCTAssertEqual(MySQLError.classify(code: 1927), .interrupted)
        XCTAssertTrue(MySQLError.server(code: 1317, sqlState: "70100", message: "Query execution was interrupted").isCancellation)
        XCTAssertTrue(MySQLError.cancelled(timedOut: true).isCancellation)
        XCTAssertEqual(MySQLError.cancelled(timedOut: true).kind, .timeout)
        XCTAssertEqual(MySQLError.cancelled(timedOut: false).kind, .interrupted)
    }

    // MARK: 类别与派生属性

    func testCategorySeparatesConnectionAndExecution() {
        let gone = MySQLError.server(code: 2013, sqlState: "HY000", message: "Lost connection to MySQL server during query")
        XCTAssertEqual(gone.category, .connection)
        XCTAssertTrue(gone.isConnectionLost)

        let syntax = MySQLError.server(code: 1064, sqlState: "42000", message: "You have an error in your SQL syntax")
        XCTAssertEqual(syntax.category, .execution)
        XCTAssertFalse(syntax.isConnectionLost)
    }

    func testUnknownDatabaseIsNotConnectionFailure() {
        let error = MySQLError.server(code: 1049, sqlState: "42000", message: "Unknown database 'nope'")
        XCTAssertEqual(error.kind, .unknownDatabase)
        XCTAssertFalse(error.isConnectionFailure, "1049 不算连接失败：连接本身是成功的")
        XCTAssertTrue(error.chineseExplanation.contains("不存在"))
    }

    func testConnectionFailureClassification() {
        XCTAssertTrue(MySQLError.connectionFailure(code: 2003, sqlState: "", message: "Can't connect").isConnectionFailure)
        XCTAssertTrue(MySQLError.connectionFailure(code: 1045, sqlState: "28000", message: "Access denied").isConnectionFailure)
        XCTAssertEqual(MySQLError.connectionFailure(code: 0, sqlState: "", message: "未知").kind, .connectionFailed)
        XCTAssertEqual(MySQLError.connectionFailure(code: 1049, sqlState: "42000", message: "Unknown database").kind, .unknownDatabase)
    }

    // MARK: 展示

    func testRawServerFieldsArePreserved() {
        let error = MySQLError.server(code: 1062, sqlState: "23000", message: "Duplicate entry '1' for key 'PRIMARY'")
        XCTAssertEqual(error.code, 1062)
        XCTAssertEqual(error.sqlState, "23000")
        XCTAssertEqual(error.message, "Duplicate entry '1' for key 'PRIMARY'")
        XCTAssertTrue(error.description.contains("1062"))
        XCTAssertTrue(error.description.contains("23000"))
        XCTAssertTrue(error.description.contains("Duplicate entry"))
    }

    func testStatementIsTrimmedTo200Characters() {
        let longSQL = String(repeating: "a", count: 500)
        let error = MySQLError.server(code: 1064, sqlState: "42000", message: "syntax", statement: longSQL)
        XCTAssertEqual(error.statement?.count, 200)
    }

    func testChineseExplanationIsAlwaysPresent() {
        for code: UInt32 in [0, 1045, 1049, 1062, 1064, 1146, 1205, 1213, 1317, 1927, 2003, 2006, 2013, 9999] {
            let error = MySQLError.server(code: code, sqlState: "", message: "raw")
            XCTAssertFalse(error.chineseExplanation.isEmpty, "错误码 \(code) 缺少中文解释")
        }
        XCTAssertFalse(MySQLError.notConnected().chineseExplanation.isEmpty)
        XCTAssertFalse(MySQLError(kind: .invalidInput, code: 0, sqlState: "", message: "").chineseExplanation.isEmpty)
    }

    func testEmptyMessageFallsBack() {
        let error = MySQLError(kind: .server, code: 1, sqlState: "", message: "")
        XCTAssertFalse(error.message.isEmpty)
    }
}
