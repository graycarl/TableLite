import XCTest
@testable import TableLite

/// `information_schema` 行 → 模型的纯函数映射。
final class MetaMappingTests: XCTestCase {

    // MARK: 类型

    func testFieldTypeMapping() {
        XCTAssertEqual(MetaMapping.fieldType(forDataType: "tinyint"), .tiny)
        XCTAssertEqual(MetaMapping.fieldType(forDataType: "BIGINT"), .longlong)
        XCTAssertEqual(MetaMapping.fieldType(forDataType: "varchar"), .varString)
        XCTAssertEqual(MetaMapping.fieldType(forDataType: "longtext"), .blob)
        XCTAssertEqual(MetaMapping.fieldType(forDataType: "json"), .json)
        XCTAssertEqual(MetaMapping.fieldType(forDataType: "enum"), .enumeration)
        // 未知类型回退为字符串，避免字面量生成走数字路径。
        XCTAssertEqual(MetaMapping.fieldType(forDataType: "weirdtype"), .varString)
        XCTAssertEqual(MetaMapping.fieldType(forDataType: nil), .varString)
    }

    // MARK: 库

    func testFilterSystemDatabases() {
        let all = ["app_dev", "information_schema", "mysql", "performance_schema", "sys", "SYS"]
        XCTAssertEqual(MetaMapping.filterSystemDatabases(all, includeSystem: false), ["app_dev"])
        XCTAssertEqual(MetaMapping.filterSystemDatabases(all, includeSystem: true), all)
    }

    func testDatabaseNames() {
        let rows = [
            MetaRow(["Database": "app_dev"]),
            MetaRow(["Database": "mysql"]),
        ]
        XCTAssertEqual(MetaMapping.databaseNames(from: rows), ["app_dev", "mysql"])
    }

    // MARK: 列 / flags

    func testColumnFlagsMapping() {
        let rows = [
            MetaRow([
                "COLUMN_NAME": "id",
                "ORDINAL_POSITION": "1",
                "IS_NULLABLE": "NO",
                "DATA_TYPE": "bigint",
                "COLUMN_TYPE": "bigint unsigned",
                "COLUMN_KEY": "PRI",
                "EXTRA": "auto_increment",
                "CHARACTER_SET_NAME": nil,
            ]),
            MetaRow([
                "COLUMN_NAME": "email",
                "ORDINAL_POSITION": "2",
                "IS_NULLABLE": "YES",
                "DATA_TYPE": "varchar",
                "COLUMN_TYPE": "varchar(255)",
                "COLUMN_KEY": "UNI",
                "EXTRA": "",
                "CHARACTER_SET_NAME": "utf8mb4",
                "COLLATION_NAME": "utf8mb4_general_ci",
            ]),
            MetaRow([
                "COLUMN_NAME": "active",
                "ORDINAL_POSITION": "3",
                "IS_NULLABLE": "NO",
                "DATA_TYPE": "tinyint",
                "COLUMN_TYPE": "tinyint(1)",
                "COLUMN_KEY": "",
                "EXTRA": "",
                "CHARACTER_SET_NAME": nil,
            ]),
        ]
        let columns = MetaMapping.columns(from: rows)
        XCTAssertEqual(columns.count, 3)

        let id = columns[0]
        XCTAssertTrue(id.isPrimaryKey)
        XCTAssertTrue(id.isAutoIncrement)
        XCTAssertTrue(id.isNotNull)
        XCTAssertTrue(id.isUnsigned)
        XCTAssertEqual(id.fieldType, .longlong)
        XCTAssertEqual(id.columnTypeText, "bigint unsigned")

        let email = columns[1]
        XCTAssertTrue(email.isUniqueKey)
        XCTAssertFalse(email.isNotNull)
        XCTAssertEqual(email.collation, "utf8mb4_general_ci")

        let active = columns[2]
        XCTAssertTrue(active.isBooleanTinyInt)
        XCTAssertEqual(active.length, 1)
    }

    func testColumnsSortedByOrdinalPosition() {
        let rows = [
            MetaRow(["COLUMN_NAME": "b", "ORDINAL_POSITION": "2", "DATA_TYPE": "int"]),
            MetaRow(["COLUMN_NAME": "a", "ORDINAL_POSITION": "1", "DATA_TYPE": "int"]),
        ]
        XCTAssertEqual(MetaMapping.columns(from: rows).map(\.name), ["a", "b"])
    }

    func testBinaryColumnFlag() {
        let rows = [
            MetaRow([
                "COLUMN_NAME": "payload",
                "DATA_TYPE": "varbinary",
                "COLUMN_TYPE": "varbinary(255)",
                "IS_NULLABLE": "YES",
                "CHARACTER_SET_NAME": nil,
            ]),
        ]
        let column = MetaMapping.columns(from: rows)[0]
        XCTAssertTrue(column.isBinary)
        XCTAssertEqual(column.charsetNumber, 63)
    }

    // MARK: 表 / 视图

    func testTablesMapping() {
        let rows = [
            MetaRow([
                "TABLE_NAME": "users",
                "TABLE_TYPE": "BASE TABLE",
                "ENGINE": "InnoDB",
                "TABLE_ROWS": "12480",
                "TABLE_COMMENT": "用户表",
                "TABLE_COLLATION": "utf8mb4_general_ci",
            ]),
            MetaRow(["TABLE_NAME": "v_users", "TABLE_TYPE": "VIEW", "ENGINE": nil]),
            MetaRow(["TABLE_NAME": "ignored", "TABLE_TYPE": "SYSTEM VIEW", "ENGINE": nil]),
        ]
        let tables = MetaMapping.tables(database: "app_dev", from: rows)
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0].name, "users")
        XCTAssertEqual(tables[0].kind, .table)
        XCTAssertEqual(tables[0].rowCountEstimate, 12480)
        XCTAssertEqual(tables[0].comment, "用户表")
        XCTAssertEqual(tables[1].kind, .view)
    }

    func testRowCountEstimate() {
        XCTAssertEqual(
            MetaMapping.rowCountEstimate(from: [MetaRow(["TABLE_ROWS": "42"])]),
            RowCountEstimate(approximate: 42, isReliable: true, isExact: false)
        )
        XCTAssertEqual(
            MetaMapping.rowCountEstimate(from: [MetaRow(["TABLE_ROWS": nil])]),
            RowCountEstimate(approximate: 0, isReliable: false, isExact: false)
        )
        XCTAssertNil(MetaMapping.rowCountEstimate(from: []))
    }

    // MARK: 服务器信息

    func testServerInfoMapping() {
        let rows = [
            MetaRow([
                "version": "8.0.36",
                "server_charset": "utf8mb4",
                "server_collation": "utf8mb4_0900_ai_ci",
                "sql_mode": "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES",
                "client_charset": "utf8mb4",
                "connection_collation": "utf8mb4_general_ci",
            ]),
        ]
        let info = MetaMapping.serverInfo(from: rows)
        XCTAssertEqual(info?.version, "8.0.36")
        XCTAssertTrue(info?.hasNoBackslashEscapes ?? false)
        XCTAssertNil(MetaMapping.serverInfo(from: []))
    }

    // MARK: 索引

    func testIndexesGrouping() {
        let rows = [
            MetaRow(["INDEX_NAME": "PRIMARY", "SEQ_IN_INDEX": "1", "COLUMN_NAME": "id", "NON_UNIQUE": "0", "INDEX_TYPE": "BTREE", "COLLATION": "A"]),
            MetaRow(["INDEX_NAME": "idx_email", "SEQ_IN_INDEX": "1", "COLUMN_NAME": "email", "NON_UNIQUE": "0", "INDEX_TYPE": "BTREE", "COLLATION": "D", "SUB_PART": "20"]),
            MetaRow(["INDEX_NAME": "idx_name", "SEQ_IN_INDEX": "1", "COLUMN_NAME": "first_name", "NON_UNIQUE": "1", "INDEX_TYPE": "BTREE"]),
            MetaRow(["INDEX_NAME": "idx_name", "SEQ_IN_INDEX": "2", "COLUMN_NAME": "last_name", "NON_UNIQUE": "1", "INDEX_TYPE": "BTREE"]),
            MetaRow(["INDEX_NAME": "ft", "SEQ_IN_INDEX": "1", "COLUMN_NAME": "body", "NON_UNIQUE": "1", "INDEX_TYPE": "FULLTEXT"]),
        ]
        let indexes = MetaMapping.indexes(from: rows)
        XCTAssertEqual(indexes.map(\.name), ["PRIMARY", "idx_email", "idx_name", "ft"])
        XCTAssertEqual(indexes[0].kind, .primary)
        XCTAssertEqual(indexes[1].kind, .unique)
        XCTAssertTrue(indexes[1].columns[0].isDescending)
        XCTAssertEqual(indexes[1].columns[0].prefixLength, 20)
        XCTAssertEqual(indexes[2].columns.map(\.name), ["first_name", "last_name"])
        XCTAssertEqual(indexes[3].kind, .fulltext)
    }

    // MARK: 外键

    func testForeignKeysGrouping() {
        let rows = [
            MetaRow([
                "CONSTRAINT_NAME": "fk_order_user",
                "COLUMN_NAME": "user_id",
                "ORDINAL_POSITION": "1",
                "REFERENCED_TABLE_SCHEMA": "app_dev",
                "REFERENCED_TABLE_NAME": "users",
                "REFERENCED_COLUMN_NAME": "id",
                "UPDATE_RULE": "CASCADE",
                "DELETE_RULE": "RESTRICT",
            ]),
        ]
        let keys = MetaMapping.foreignKeys(from: rows)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].name, "fk_order_user")
        XCTAssertEqual(keys[0].columns, ["user_id"])
        XCTAssertEqual(keys[0].referencedTable, "users")
        XCTAssertEqual(keys[0].onDelete, "RESTRICT")
        XCTAssertEqual(keys[0].referencedDisplayName, "app_dev.users")
    }

    func testForeignKeysSkipsRowsWithoutReference() {
        let rows = [
            MetaRow(["CONSTRAINT_NAME": "fk", "COLUMN_NAME": "x", "REFERENCED_TABLE_NAME": nil]),
        ]
        XCTAssertTrue(MetaMapping.foreignKeys(from: rows).isEmpty)
    }

    // MARK: 触发器

    func testTriggersMapping() {
        let rows = [
            MetaRow([
                "TRIGGER_NAME": "trg_audit",
                "ACTION_TIMING": "AFTER",
                "EVENT_MANIPULATION": "UPDATE",
                "ACTION_STATEMENT": "BEGIN … END",
            ]),
        ]
        let triggers = MetaMapping.triggers(from: rows)
        XCTAssertEqual(triggers.first?.timing, .after)
        XCTAssertEqual(triggers.first?.event, .update)
    }

    // MARK: DDL 失效

    func testDDLInvalidationQualifiedTable() {
        let result = MetaMapping.ddlInvalidation(in: "CREATE TABLE app_dev.users (id INT)")
        XCTAssertTrue(result.containsDDL)
        XCTAssertTrue(result.tables.contains(TableRef(database: "app_dev", table: "users")))
        XCTAssertFalse(result.unresolved)
    }

    func testDDLInvalidationUnqualifiedTable() {
        let result = MetaMapping.ddlInvalidation(in: "ALTER TABLE users ADD COLUMN x INT")
        XCTAssertTrue(result.containsDDL)
        XCTAssertTrue(result.unqualifiedTables.contains("users"))
        XCTAssertEqual(result.resolvedTables(currentDatabase: "app_dev"), [TableRef(database: "app_dev", table: "users")])
    }

    func testDDLInvalidationDropTableList() {
        let result = MetaMapping.ddlInvalidation(in: "DROP TABLE IF EXISTS `a`, `b`;")
        XCTAssertTrue(result.containsDDL)
        XCTAssertEqual(result.unqualifiedTables, ["a", "b"])
    }

    func testDDLInvalidationDatabase() {
        let result = MetaMapping.ddlInvalidation(in: "DROP DATABASE old_db")
        XCTAssertTrue(result.invalidatesWholeDatabase)
        XCTAssertTrue(result.databases.contains("old_db"))
    }

    func testNonDDLReturnsEmpty() {
        let result = MetaMapping.ddlInvalidation(in: "SELECT * FROM users WHERE x = 1 /* DROP TABLE t */")
        XCTAssertFalse(result.containsDDL)
    }

    func testDDLInvalidationUnresolvedForRoutine() {
        let result = MetaMapping.ddlInvalidation(in: "CREATE PROCEDURE p() BEGIN END")
        XCTAssertTrue(result.containsDDL)
        XCTAssertTrue(result.unresolved)
    }
}
