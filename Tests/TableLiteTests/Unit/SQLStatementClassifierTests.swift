import XCTest
@testable import TableLite

/// 语句类型判定与只读白名单，重点覆盖以 CTE 开头的写语句。
///
/// 见 `docs/tech-designs/10-query-editor.md` §10。
final class SQLStatementClassifierTests: XCTestCase {

    func testBasicKinds() {
        XCTAssertEqual(SQLStatementClassifier.classify("SELECT 1"), .query)
        XCTAssertEqual(SQLStatementClassifier.classify("SHOW TABLES"), .query)
        XCTAssertEqual(SQLStatementClassifier.classify("EXPLAIN SELECT 1"), .query)
        XCTAssertEqual(SQLStatementClassifier.classify("DESC users"), .query)
        XCTAssertEqual(SQLStatementClassifier.classify("INSERT INTO t VALUES (1)"), .dml)
        XCTAssertEqual(SQLStatementClassifier.classify("UPDATE t SET a=1"), .dml)
        XCTAssertEqual(SQLStatementClassifier.classify("DELETE FROM t"), .dml)
        XCTAssertEqual(SQLStatementClassifier.classify("CREATE TABLE t (a INT)"), .ddl)
        XCTAssertEqual(SQLStatementClassifier.classify("ALTER TABLE t ADD b INT"), .ddl)
        XCTAssertEqual(SQLStatementClassifier.classify("CALL p()"), .other)
        XCTAssertEqual(SQLStatementClassifier.classify("SET @a = 1"), .other)
    }

    func testLeadingCommentIsIgnored() {
        XCTAssertEqual(SQLStatementClassifier.classify("-- hi\nSELECT 1"), .query)
        XCTAssertEqual(SQLStatementClassifier.classify("/* c */ INSERT INTO t VALUES (1)"), .dml)
    }

    func testCTEQuery() {
        let sql = "WITH x AS (SELECT 1) SELECT * FROM x"
        XCTAssertEqual(SQLStatementClassifier.classify(sql), .query)
        XCTAssertTrue(SQLStatementClassifier.isReadOnlyAllowed(sql))
    }

    func testCTEWriteIsNotAllowed() {
        let sql = "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x"
        XCTAssertEqual(SQLStatementClassifier.classify(sql), .dml)
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed(sql))
    }

    func testNestedCTEWriteIsNotAllowed() {
        let sql = "WITH RECURSIVE x AS (SELECT 1 UNION ALL SELECT 2) UPDATE t SET a = 1"
        XCTAssertEqual(SQLStatementClassifier.classify(sql), .dml)
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed(sql))
    }

    func testReadOnlyWhitelist() {
        XCTAssertTrue(SQLStatementClassifier.isReadOnlyAllowed("SELECT 1"))
        XCTAssertTrue(SQLStatementClassifier.isReadOnlyAllowed("SHOW TABLES"))
        XCTAssertTrue(SQLStatementClassifier.isReadOnlyAllowed("EXPLAIN SELECT 1"))
        XCTAssertTrue(SQLStatementClassifier.isReadOnlyAllowed("DESCRIBE users"))
        XCTAssertTrue(SQLStatementClassifier.isReadOnlyAllowed("DESC users"))
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed("INSERT INTO t VALUES (1)"))
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed("CREATE TABLE t (a INT)"))
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed("CALL p()"))
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed("SET @a = 1"))
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed("LOAD DATA INFILE 'x' INTO TABLE t"))
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed("VALUES (1)"))
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed(""))
    }

    func testContainsDDL() {
        XCTAssertTrue(SQLStatementClassifier.containsDDL("CREATE TABLE t (a INT)"))
        XCTAssertTrue(SQLStatementClassifier.containsDDL("DROP TABLE t"))
        XCTAssertTrue(SQLStatementClassifier.containsDDL("ALTER TABLE t ADD b INT"))
        XCTAssertTrue(SQLStatementClassifier.containsDDL("TRUNCATE TABLE t"))
        XCTAssertFalse(SQLStatementClassifier.containsDDL("SELECT 'drop table t'"))
        XCTAssertFalse(SQLStatementClassifier.containsDDL("SELECT 1"))
        XCTAssertFalse(SQLStatementClassifier.containsDDL("-- DROP TABLE t\nSELECT 1"))
    }

    func testValuesAndTableClassifyAsQueryButAreNotReadOnly() {
        XCTAssertEqual(SQLStatementClassifier.classify("VALUES (1)"), .query)
        XCTAssertFalse(SQLStatementClassifier.isReadOnlyAllowed("VALUES (1)"))
    }

    func testUseStatementDetection() {
        XCTAssertTrue(SQLStatementClassifier.isUseStatement("USE app_dev"))
        XCTAssertTrue(SQLStatementClassifier.isUseStatement("USE `app_dev`;"))
        XCTAssertTrue(SQLStatementClassifier.isUseStatement("use app_dev;"))
        XCTAssertTrue(SQLStatementClassifier.isUseStatement("-- 切库\nUSE app_dev"))
        XCTAssertTrue(SQLStatementClassifier.isUseStatement("/* c */ USE app_dev"))
        XCTAssertFalse(SQLStatementClassifier.isUseStatement(""))
        XCTAssertFalse(SQLStatementClassifier.isUseStatement("SELECT 1"))
        // `USE INDEX` 不是起始关键字，不能误判。
        XCTAssertFalse(SQLStatementClassifier.isUseStatement("SELECT * FROM t USE INDEX (i)"))
        XCTAssertFalse(SQLStatementClassifier.isUseStatement("USER()"))
        XCTAssertFalse(SQLStatementClassifier.isUseStatement("UPDATE t SET `use` = 1"))
    }
}
