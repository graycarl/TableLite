import XCTest
@testable import TableLite

/// `MetaMapping` 纯函数覆盖：`information_schema` 行 → Core 模型，以及 DDL 缓存失效判定。
/// 见 docs/tech-designs/11-schema-and-import-export.md §1、specs/07-schema-view.md。
final class MetaMappingTests: XCTestCase {

    // MARK: 构造工具

    private func metaColumn(_ name: String) -> ResultSetColumn {
        ResultSetColumn(
            name: name,
            originalTable: nil,
            originalColumn: nil,
            database: nil,
            fieldType: MySQLFieldType.varString,
            flags: 0,
            charsetNumber: 0,
            length: 0,
            decimals: 0,
            kind: .text,
            isBinary: false,
            isNotNull: false,
            isPrimaryKey: false,
            isUnsigned: false,
            isAutoIncrement: false
        )
    }

    private func reader(_ pairs: [(String, CellValue)]) -> ResultRowReader {
        ResultRowReader(columns: pairs.map { metaColumn($0.0) }, values: pairs.map { $0.1 })
    }

    /// 所有行必须给出相同的列名顺序（按第一行建表头）。
    private func resultSet(_ rows: [[(String, CellValue)]]) -> MaterializedResultSet {
        let columns = rows.first?.map { metaColumn($0.0) } ?? []
        let values = rows.map { $0.map { $0.1 } }
        return MaterializedResultSet(
            header: ResultSetHeader(index: 0, columns: columns, affectedRows: 0, lastInsertID: 0),
            rows: values
        )
    }

    // MARK: 列类型

    func testTinyInt1ParsesAsBoolean() {
        let column = MetaMapping.tableColumn(from: reader([
            ("ORDINAL_POSITION", .text("1")),
            ("COLUMN_NAME", .text("flag")),
            ("DATA_TYPE", .text("tinyint")),
            ("COLUMN_TYPE", .text("tinyint(1)")),
            ("IS_NULLABLE", .text("NO")),
            ("COLUMN_KEY", .text("")),
            ("COLUMN_DEFAULT", .text("0")),
            ("EXTRA", .text("")),
            ("COLUMN_COMMENT", .text("")),
        ]))
        XCTAssertEqual(column?.kind, .boolean)
        XCTAssertEqual(column?.isTinyInt1, true)
        XCTAssertEqual(column?.isUnsigned, false)
        XCTAssertEqual(column?.defaultValue, "0")
    }

    func testBigIntUnsigned() {
        let column = MetaMapping.tableColumn(from: reader([
            ("ORDINAL_POSITION", .text("1")),
            ("COLUMN_NAME", .text("id")),
            ("DATA_TYPE", .text("bigint")),
            ("COLUMN_TYPE", .text("bigint unsigned")),
            ("IS_NULLABLE", .text("NO")),
        ]))
        XCTAssertEqual(column?.kind, .integer(isUnsigned: true))
        XCTAssertEqual(column?.isUnsigned, true)
        // 非空且没有 DEFAULT 子句（information_schema 返回 SQL NULL）→ 没有默认值
        XCTAssertNil(column?.defaultValue)
    }

    func testEnumValues() {
        let column = MetaMapping.tableColumn(from: reader([
            ("COLUMN_NAME", .text("status")),
            ("DATA_TYPE", .text("enum")),
            ("COLUMN_TYPE", .text("enum('a','b')")),
            ("IS_NULLABLE", .text("YES")),
        ]))
        XCTAssertEqual(column?.kind, .enumType)
        XCTAssertEqual(column?.enumValues, ["a", "b"])
    }

    func testDecimalKeepsRawTypeText() {
        let column = MetaMapping.tableColumn(from: reader([
            ("COLUMN_NAME", .text("price")),
            ("DATA_TYPE", .text("decimal")),
            ("COLUMN_TYPE", .text("decimal(10,2)")),
            ("IS_NULLABLE", .text("YES")),
        ]))
        XCTAssertEqual(column?.kind, .decimal)
        XCTAssertEqual(column?.rawTypeText, "decimal(10,2)")
    }

    // MARK: 可空 / 主键 / 自增 / 默认值

    func testNullablePrimaryKeyAutoIncrement() {
        let column = MetaMapping.tableColumn(from: reader([
            ("ORDINAL_POSITION", .text("1")),
            ("COLUMN_NAME", .text("id")),
            ("DATA_TYPE", .text("int")),
            ("COLUMN_TYPE", .text("int unsigned")),
            ("IS_NULLABLE", .text("NO")),
            ("COLUMN_KEY", .text("PRI")),
            ("COLUMN_DEFAULT", .null),
            ("EXTRA", .text("auto_increment")),
            ("COLUMN_COMMENT", .text("主键")),
        ]))
        XCTAssertEqual(column?.isNullable, false)
        XCTAssertEqual(column?.isPrimaryKey, true)
        XCTAssertEqual(column?.isAutoIncrement, true)
        XCTAssertEqual(column?.isUnsigned, true)
        XCTAssertEqual(column?.comment, "主键")
        XCTAssertNil(column?.defaultValue)
    }

    func testDefaultValueSemantics() {
        // 可空 + SQL NULL → 隐式 NULL 默认
        XCTAssertEqual(MetaMapping.defaultLiteral(CellValue.null, isNullable: true), "NULL")
        // 非空 + SQL NULL → 没有默认值
        XCTAssertNil(MetaMapping.defaultLiteral(CellValue.null, isNullable: false))
        // 列不存在（视图等）→ 没有默认值
        XCTAssertNil(MetaMapping.defaultLiteral(nil, isNullable: true))
        // 普通字符串默认值
        XCTAssertEqual(MetaMapping.defaultLiteral(.text("0"), isNullable: false), "0")
        XCTAssertEqual(MetaMapping.defaultLiteral(.text(""), isNullable: true), "")
    }

    func testInvisibleAndGeneratedColumns() {
        let invisible = MetaMapping.tableColumn(from: reader([
            ("COLUMN_NAME", .text("secret")),
            ("DATA_TYPE", .text("int")),
            ("COLUMN_TYPE", .text("int")),
            ("IS_NULLABLE", .text("YES")),
            ("EXTRA", .text("INVISIBLE")),
        ]))
        XCTAssertEqual(invisible?.isInvisible, true)
        XCTAssertEqual(invisible?.isGenerated, false)

        let generated = MetaMapping.tableColumn(from: reader([
            ("COLUMN_NAME", .text("total")),
            ("DATA_TYPE", .text("int")),
            ("COLUMN_TYPE", .text("int")),
            ("IS_NULLABLE", .text("YES")),
            ("EXTRA", .text("VIRTUAL GENERATED")),
            ("COLUMN_DEFAULT", .null),
        ]))
        XCTAssertEqual(generated?.isGenerated, true)
        // 生成列没有默认值
        XCTAssertNil(generated?.defaultValue)
    }

    func testDefaultGeneratedExpressionIsNotGeneratedColumn() {
        let column = MetaMapping.tableColumn(from: reader([
            ("COLUMN_NAME", .text("created_at")),
            ("DATA_TYPE", .text("timestamp")),
            ("COLUMN_TYPE", .text("timestamp")),
            ("IS_NULLABLE", .text("NO")),
            ("COLUMN_DEFAULT", .text("CURRENT_TIMESTAMP")),
            ("EXTRA", .text("DEFAULT_GENERATED")),
        ]))
        XCTAssertEqual(column?.isGenerated, false)
        XCTAssertEqual(column?.defaultValue, "CURRENT_TIMESTAMP")
    }

    // MARK: charset / 二进制

    func testTextColumnCharsetAndBinaryColumn() {
        let text = MetaMapping.tableColumn(from: reader([
            ("COLUMN_NAME", .text("name")),
            ("DATA_TYPE", .text("varchar")),
            ("COLUMN_TYPE", .text("varchar(255)")),
            ("IS_NULLABLE", .text("YES")),
            ("CHARACTER_SET_NAME", .text("utf8mb4")),
            ("COLLATION_NAME", .text("utf8mb4_0900_ai_ci")),
        ]))
        XCTAssertEqual(text?.charset, "utf8mb4")
        XCTAssertEqual(text?.collation, "utf8mb4_0900_ai_ci")
        XCTAssertEqual(text?.isBinary, false)

        let blob = MetaMapping.tableColumn(from: reader([
            ("COLUMN_NAME", .text("payload")),
            ("DATA_TYPE", .text("blob")),
            ("COLUMN_TYPE", .text("blob")),
            ("IS_NULLABLE", .text("YES")),
        ]))
        XCTAssertEqual(blob?.kind, .blob)
        XCTAssertEqual(blob?.isBinary, true)

        let varbinary = MetaMapping.tableColumn(from: reader([
            ("COLUMN_NAME", .text("raw")),
            ("DATA_TYPE", .text("varbinary")),
            ("COLUMN_TYPE", .text("varbinary(16)")),
            ("IS_NULLABLE", .text("YES")),
        ]))
        XCTAssertEqual(varbinary?.isBinary, true)
    }

    func testColumnsSortedByPosition() {
        let result = resultSet([
            [("ORDINAL_POSITION", .text("2")), ("COLUMN_NAME", .text("b")),
             ("DATA_TYPE", .text("int")), ("COLUMN_TYPE", .text("int")), ("IS_NULLABLE", .text("YES"))],
            [("ORDINAL_POSITION", .text("1")), ("COLUMN_NAME", .text("a")),
             ("DATA_TYPE", .text("int")), ("COLUMN_TYPE", .text("int")), ("IS_NULLABLE", .text("YES"))],
        ])
        XCTAssertEqual(MetaMapping.columns(from: result).map(\.name), ["a", "b"])
    }

    // MARK: 索引

    func testIndexesClassifyAndOrder() {
        let result = resultSet([
            [("INDEX_NAME", .text("idx_name")), ("NON_UNIQUE", .text("1")), ("SEQ_IN_INDEX", .text("1")),
             ("COLUMN_NAME", .text("name")), ("COLLATION", .text("A")), ("CARDINALITY", .text("12")),
             ("INDEX_TYPE", .text("BTREE")), ("INDEX_COMMENT", .text(""))],
            [("INDEX_NAME", .text("PRIMARY")), ("NON_UNIQUE", .text("0")), ("SEQ_IN_INDEX", .text("1")),
             ("COLUMN_NAME", .text("id")), ("COLLATION", .text("A")), ("CARDINALITY", .text("100")),
             ("INDEX_TYPE", .text("BTREE")), ("INDEX_COMMENT", .text(""))],
            [("INDEX_NAME", .text("uniq_email")), ("NON_UNIQUE", .text("0")), ("SEQ_IN_INDEX", .text("1")),
             ("COLUMN_NAME", .text("email")), ("COLLATION", .text("D")), ("CARDINALITY", .text("99")),
             ("INDEX_TYPE", .text("BTREE")), ("INDEX_COMMENT", .text("邮箱唯一"))],
        ])
        let indexes = MetaMapping.indexes(from: result)
        XCTAssertEqual(indexes.map(\.name), ["PRIMARY", "idx_name", "uniq_email"])
        XCTAssertEqual(indexes[0].indexType, "PRIMARY")
        XCTAssertEqual(indexes[1].indexType, "INDEX")
        XCTAssertEqual(indexes[2].indexType, "UNIQUE")
        XCTAssertEqual(indexes[1].cardinality, 12)
        XCTAssertEqual(indexes[2].comment, "邮箱唯一")
        XCTAssertEqual(indexes[2].columns.first?.descending, true)
    }

    func testCompositeIndexGroupsColumnsInOrder() {
        let result = resultSet([
            [("INDEX_NAME", .text("PRIMARY")), ("NON_UNIQUE", .text("0")), ("SEQ_IN_INDEX", .text("1")),
             ("COLUMN_NAME", .text("a")), ("COLLATION", .text("A")), ("CARDINALITY", .text("10")),
             ("INDEX_TYPE", .text("BTREE")), ("INDEX_COMMENT", .text(""))],
            [("INDEX_NAME", .text("PRIMARY")), ("NON_UNIQUE", .text("0")), ("SEQ_IN_INDEX", .text("2")),
             ("COLUMN_NAME", .text("b")), ("COLLATION", .text("D")), ("CARDINALITY", .text("10")),
             ("INDEX_TYPE", .text("BTREE")), ("INDEX_COMMENT", .text(""))],
        ])
        let index = MetaMapping.indexes(from: result).first
        XCTAssertEqual(index?.columns.map(\.name), ["a", "b"])
        XCTAssertEqual(index?.columns.map(\.descending), [false, true])
    }

    func testIndexDisplayType() {
        XCTAssertEqual(MetaMapping.indexDisplayType(name: "ft_body", nonUnique: true, rawIndexType: "FULLTEXT"), "FULLTEXT")
        XCTAssertEqual(MetaMapping.indexDisplayType(name: "sp", nonUnique: true, rawIndexType: "SPATIAL"), "SPATIAL")
        XCTAssertEqual(MetaMapping.indexDisplayType(name: "PRIMARY", nonUnique: false, rawIndexType: "BTREE"), "PRIMARY")
        XCTAssertEqual(MetaMapping.indexDisplayType(name: "u", nonUnique: false, rawIndexType: "BTREE"), "UNIQUE")
        XCTAssertEqual(MetaMapping.indexDisplayType(name: "i", nonUnique: true, rawIndexType: "BTREE"), "INDEX")
    }

    // MARK: 外键

    func testForeignKeys() {
        let result = resultSet([
            [("CONSTRAINT_NAME", .text("fk_user")), ("COLUMN_NAME", .text("user_id")), ("ORDINAL_POSITION", .text("1")),
             ("REFERENCED_TABLE_SCHEMA", .text("shop")), ("REFERENCED_TABLE_NAME", .text("users")),
             ("REFERENCED_COLUMN_NAME", .text("id")), ("DELETE_RULE", .text("CASCADE")), ("UPDATE_RULE", .text("SET NULL"))],
            [("CONSTRAINT_NAME", .text("fk_user")), ("COLUMN_NAME", .text("tenant_id")), ("ORDINAL_POSITION", .text("2")),
             ("REFERENCED_TABLE_SCHEMA", .text("shop")), ("REFERENCED_TABLE_NAME", .text("users")),
             ("REFERENCED_COLUMN_NAME", .text("tenant_id")), ("DELETE_RULE", .text("CASCADE")), ("UPDATE_RULE", .text("SET NULL"))],
        ])
        let foreignKey = MetaMapping.foreignKeys(from: result).first
        XCTAssertEqual(foreignKey?.name, "fk_user")
        XCTAssertEqual(foreignKey?.columns, ["user_id", "tenant_id"])
        XCTAssertEqual(foreignKey?.referencedDatabase, "shop")
        XCTAssertEqual(foreignKey?.referencedTable, "users")
        XCTAssertEqual(foreignKey?.referencedColumns, ["id", "tenant_id"])
        XCTAssertEqual(foreignKey?.onDelete, "CASCADE")
        XCTAssertEqual(foreignKey?.onUpdate, "SET NULL")
        XCTAssertEqual(foreignKey?.referencedDisplay, "shop.users")
    }

    // MARK: 触发器

    func testTriggers() {
        let result = resultSet([
            [("TRIGGER_NAME", .text("trg_before_insert")), ("ACTION_TIMING", .text("BEFORE")),
             ("EVENT_MANIPULATION", .text("INSERT")), ("ACTION_STATEMENT", .text("BEGIN ... END"))],
            [("TRIGGER_NAME", .text("trg_after_update")), ("ACTION_TIMING", .text("AFTER")),
             ("EVENT_MANIPULATION", .text("UPDATE")), ("ACTION_STATEMENT", .text("SET ..."))],
            [("TRIGGER_NAME", .text("trg_after_delete")), ("ACTION_TIMING", .text("AFTER")),
             ("EVENT_MANIPULATION", .text("DELETE")), ("ACTION_STATEMENT", .text("..."))],
        ])
        let triggers = MetaMapping.triggers(from: result)
        XCTAssertEqual(triggers.map(\.timing), ["BEFORE", "AFTER", "AFTER"])
        XCTAssertEqual(triggers.map(\.event), ["INSERT", "UPDATE", "DELETE"])
        XCTAssertEqual(triggers.first?.statement, "BEGIN ... END")
    }

    // MARK: 系统库过滤

    func testSystemDatabaseFilter() {
        XCTAssertTrue(MetaMapping.isSystemDatabase("information_schema"))
        XCTAssertTrue(MetaMapping.isSystemDatabase("performance_schema"))
        XCTAssertTrue(MetaMapping.isSystemDatabase("MYSQL"))
        XCTAssertTrue(MetaMapping.isSystemDatabase("Sys"))
        XCTAssertFalse(MetaMapping.isSystemDatabase("shop"))
    }

    func testDatabaseNamesSkipsNullAndEmpty() {
        let result = resultSet([
            [("Database", .text("information_schema"))],
            [("Database", .text("shop"))],
            [("Database", .null)],
            [("Database", .text(""))],
        ])
        XCTAssertEqual(MetaMapping.databaseNames(from: result), ["information_schema", "shop"])
    }

    // MARK: 对象列表 / 建表语句 / 行数

    func testObjectsKindSortAndComment() {
        let result = resultSet([
            [("TABLE_NAME", .text("users")), ("TABLE_TYPE", .text("BASE TABLE")),
             ("TABLE_ROWS", .text("42")), ("TABLE_COMMENT", .text("用户"))],
            [("TABLE_NAME", .text("order_view")), ("TABLE_TYPE", .text("VIEW")),
             ("TABLE_ROWS", .null), ("TABLE_COMMENT", .text("VIEW"))],
            [("TABLE_NAME", .text("orders")), ("TABLE_TYPE", .text("BASE TABLE")),
             ("TABLE_ROWS", .null), ("TABLE_COMMENT", .text(""))],
        ])
        let objects = MetaMapping.objects(from: result)
        XCTAssertEqual(objects.map(\.name), ["order_view", "orders", "users"])
        XCTAssertEqual(objects[0].kind, .view)
        XCTAssertNil(objects[0].rowEstimate)
        XCTAssertNil(objects[0].comment, "视图的 TABLE_COMMENT 固定是 VIEW，不是用户注释")
        XCTAssertEqual(objects[1].kind, .table)
        XCTAssertNil(objects[1].rowEstimate)
        XCTAssertNil(objects[1].comment)
        XCTAssertEqual(objects[2].rowEstimate, 42)
        XCTAssertEqual(objects[2].comment, "用户")
    }

    func testCreateStatementTable() {
        let result = resultSet([
            [("Table", .text("users")), ("Create Table", .text("CREATE TABLE `users` (...)"))],
        ])
        let create = MetaMapping.createStatement(from: result)
        XCTAssertEqual(create?.kind, .table)
        XCTAssertEqual(create?.sql, "CREATE TABLE `users` (...)")
    }

    func testCreateStatementView() {
        let result = resultSet([
            [("View", .text("v")), ("Create View", .text("CREATE VIEW `v` AS SELECT 1")),
             ("character_set_client", .text("utf8mb4")), ("collation_connection", .text("utf8mb4_0900_ai_ci"))],
        ])
        let create = MetaMapping.createStatement(from: result)
        XCTAssertEqual(create?.kind, .view)
        XCTAssertEqual(create?.sql, "CREATE VIEW `v` AS SELECT 1")
    }

    func testRowEstimate() {
        XCTAssertEqual(MetaMapping.rowEstimate(from: resultSet([[("TABLE_ROWS", .text("12345"))]])), 12345)
        XCTAssertNil(MetaMapping.rowEstimate(from: resultSet([[("TABLE_ROWS", .null)]])))
    }

    func testEmptyAndNilResultsMapToEmpty() {
        XCTAssertTrue(MetaMapping.columns(from: nil).isEmpty)
        XCTAssertTrue(MetaMapping.indexes(from: nil).isEmpty)
        XCTAssertTrue(MetaMapping.foreignKeys(from: nil).isEmpty)
        XCTAssertTrue(MetaMapping.triggers(from: nil).isEmpty)
        XCTAssertTrue(MetaMapping.objects(from: nil).isEmpty)
        XCTAssertTrue(MetaMapping.databaseNames(from: nil).isEmpty)
        XCTAssertNil(MetaMapping.createStatement(from: nil))
        XCTAssertNil(MetaMapping.rowEstimate(from: nil))
        XCTAssertNil(MetaMapping.tableInfo(from: nil))
    }

    // MARK: DDL 缓存失效判定

    func testDDLQualifiedTable() {
        let invalidation = MetaMapping.ddlInvalidation(
            in: "ALTER TABLE `shop`.`users` ADD COLUMN `nick` VARCHAR(20);"
        )
        XCTAssertTrue(invalidation.containsDDL)
        XCTAssertEqual(invalidation.tables, [TableRef(database: "shop", table: "users")])
        XCTAssertTrue(invalidation.unqualifiedTables.isEmpty)
        XCTAssertFalse(invalidation.unresolved)
    }

    func testDDLUnqualifiedDropList() {
        let invalidation = MetaMapping.ddlInvalidation(in: "DROP TABLE IF EXISTS users, orders;")
        XCTAssertTrue(invalidation.containsDDL)
        XCTAssertTrue(invalidation.tables.isEmpty)
        XCTAssertEqual(invalidation.unqualifiedTables, ["users", "orders"])
        XCTAssertFalse(invalidation.unresolved)
    }

    func testDDLDatabase() {
        let invalidation = MetaMapping.ddlInvalidation(in: "DROP DATABASE `shop`;")
        XCTAssertEqual(invalidation.databases, ["shop"])
        XCTAssertFalse(invalidation.unresolved)
    }

    func testDDLIndexOnTable() {
        let invalidation = MetaMapping.ddlInvalidation(in: "CREATE INDEX idx_name ON users (name);")
        XCTAssertEqual(invalidation.unqualifiedTables, ["users"])
    }

    func testDDLTriggerOnTable() {
        let invalidation = MetaMapping.ddlInvalidation(
            in: "CREATE TRIGGER trg AFTER INSERT ON users FOR EACH ROW SET @x = 1;"
        )
        XCTAssertEqual(invalidation.unqualifiedTables, ["users"])
    }

    func testDDLRenameTable() {
        let invalidation = MetaMapping.ddlInvalidation(in: "RENAME TABLE old_users TO new_users;")
        XCTAssertEqual(invalidation.unqualifiedTables, ["old_users", "new_users"])
        XCTAssertFalse(invalidation.unresolved)
    }

    func testDDLTruncate() {
        let invalidation = MetaMapping.ddlInvalidation(in: "TRUNCATE TABLE users;")
        XCTAssertEqual(invalidation.unqualifiedTables, ["users"])
    }

    func testAlterRenameColumnDoesNotAddBogusTable() {
        let invalidation = MetaMapping.ddlInvalidation(in: "ALTER TABLE `users` RENAME COLUMN `a` TO `b`;")
        XCTAssertEqual(invalidation.unqualifiedTables, ["users"])
        XCTAssertFalse(invalidation.unresolved)
    }

    func testCreateUserIsNotTreatedAsTableDDL() {
        let invalidation = MetaMapping.ddlInvalidation(in: "CREATE USER 'app'@'%' IDENTIFIED BY 'x';")
        XCTAssertTrue(invalidation.containsDDL)
        XCTAssertFalse(invalidation.unresolved)
        XCTAssertTrue(invalidation.tables.isEmpty)
        XCTAssertTrue(invalidation.unqualifiedTables.isEmpty)
        XCTAssertTrue(invalidation.databases.isEmpty)
    }

    func testNonDDLIsIgnored() {
        let invalidation = MetaMapping.ddlInvalidation(
            in: "INSERT INTO users (id) VALUES (1); SELECT * FROM users; SHOW CREATE TABLE users;"
        )
        XCTAssertFalse(invalidation.containsDDL)
        XCTAssertTrue(invalidation.tables.isEmpty)
        XCTAssertFalse(invalidation.unresolved)
    }

    func testDDLInsideStringIsIgnored() {
        let invalidation = MetaMapping.ddlInvalidation(
            in: "INSERT INTO logs (message) VALUES ('DROP TABLE users');"
        )
        XCTAssertFalse(invalidation.containsDDL)
    }
}
