import XCTest
@testable import TableLite

/// 模型层其余部分的契约：标识符引用、Schema 模型、过滤状态、值编码、行身份。
final class ModelSupportTests: XCTestCase {

    // MARK: SQLIdentifier

    func testIdentifierQuoting() {
        XCTAssertEqual(SQLIdentifier.quote("users"), "`users`")
        XCTAssertEqual(SQLIdentifier.quote("a`b"), "`a``b`")
        XCTAssertEqual(SQLIdentifier.qualified(database: "db", table: "t"), "`db`.`t`")
        XCTAssertEqual(SQLIdentifier.qualified(database: nil, table: "t"), "`t`")
        XCTAssertEqual(SQLIdentifier.qualified(database: "", table: "t"), "`t`")
        XCTAssertEqual(SQLIdentifier.quoteList(["a", "b"]), "`a`, `b`")
    }

    // MARK: SQLValue

    func testSQLValueCodableRoundTrip() throws {
        let values: [SQLValue] = [
            .null, .text("hello"), .integer(-9), .decimal("1.25"), .bool(true), .binary(Data([0x01, 0x02])),
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(SQLValue.self, from: data), value)
        }
    }

    func testSQLValueIdentityTextDiffers() {
        XCTAssertNotEqual(SQLValue.text("1").identityText, SQLValue.integer(1).identityText)
        XCTAssertNotEqual(SQLValue.null.identityText, SQLValue.text("").identityText)
    }

    // MARK: 行身份

    func testRowLocatorIdentityIsStable() {
        let a = TestSupport.locator(id: "5")
        let b = TestSupport.locator(id: "5")
        XCTAssertEqual(a.identityString, b.identityString)
    }

    func testRowLocatorIdentityDistinguishesValues() {
        XCTAssertNotEqual(
            TestSupport.locator(id: "5").identityString,
            TestSupport.locator(id: "6").identityString
        )
    }

    func testRowLocatorIdentityHandlesSeparators() {
        // 值里含分隔符也不应碰撞。
        let a = RowLocator(keys: [RowKeyValue(column: "a", value: .text("x;y"), fieldType: .varString)])
        let b = RowLocator(keys: [
            RowKeyValue(column: "a", value: .text("x"), fieldType: .varString),
            RowKeyValue(column: "b", value: .text("y"), fieldType: .varString),
        ])
        XCTAssertNotEqual(a.identityString, b.identityString)
    }

    // MARK: PendingChange Codable

    func testPendingChangeCodableRoundTrip() throws {
        let changes: [PendingChange] = [
            .insertion(id: UUID(), edits: [TestSupport.edit("name", .text("x"))]),
            .update(locator: TestSupport.locator(), edits: [TestSupport.edit("age", .integer(3))]),
            .deletion(locator: TestSupport.locator(id: "9")),
        ]
        let data = try JSONEncoder().encode(changes)
        let decoded = try JSONDecoder().decode([PendingChange].self, from: data)
        XCTAssertEqual(decoded, changes)
    }

    // MARK: Schema 模型

    func testTableStructureSummaryAndPrimaryKey() {
        let table = TableInfo(database: "db", name: "users", kind: .table, rowCountEstimate: 100)
        let id = TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63)
        let name = TestSupport.column("name")
        let structure = TableStructure(
            table: table,
            columns: [id, name],
            indexes: [IndexInfo(name: "PRIMARY", kind: .primary, columns: [IndexColumn(name: "id")])],
            foreignKeys: [
                ForeignKeyInfo(
                    name: "fk_role",
                    columns: ["role_id"],
                    referencedDatabase: "db",
                    referencedTable: "roles",
                    referencedColumns: ["id"],
                    onDelete: "CASCADE"
                ),
            ],
            triggers: [TriggerInfo(name: "trg", timing: .before, event: .insert, statement: "SET NEW.x = 1")],
            createStatement: "CREATE TABLE ..."
        )
        XCTAssertEqual(structure.primaryKeyColumns.map(\.name), ["id"])
        XCTAssertEqual(structure.summary, "2 列 · 1 索引 · 1 外键 · 1 触发器")
        XCTAssertEqual(structure.foreignKeys[0].referencedDisplayName, "db.roles")
    }

    func testIndexKindDisplayNames() {
        XCTAssertEqual(IndexKind.primary.displayName, "PRIMARY")
        XCTAssertEqual(IndexKind.normal.displayName, "普通")
        XCTAssertEqual(IndexKind.fulltext.displayName, "全文")
    }

    func testSchemaObjectIdentity() {
        XCTAssertEqual(SchemaObject(database: "db", name: "t", kind: .table).id, "db.t")
    }

    // MARK: 过滤状态

    func testFilterStateActiveAndReferencedColumns() {
        var state = FilterState()
        XCTAssertFalse(state.isActive)
        state.conditions = [
            FilterCondition(isEnabled: true, column: "a", op: .equal, value: "1"),
            FilterCondition(isEnabled: false, column: "b", op: .equal, value: "2"),
        ]
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.referencedColumns, ["a"])
    }

    func testFilterStateModeSwitchingClearsOtherSide() {
        var state = FilterState()
        state.conditions = [FilterCondition(column: "a", op: .equal, value: "1")]
        state.switchToRawMode()
        XCTAssertTrue(state.isRawMode)
        XCTAssertTrue(state.conditions.isEmpty)

        state.rawWhere = "a = 1"
        state.switchToConditionsMode()
        XCTAssertFalse(state.isRawMode)
        XCTAssertTrue(state.rawWhere.isEmpty)
    }

    func testFilterOperatorProperties() {
        XCTAssertFalse(FilterOperator.isNull.requiresValue)
        XCTAssertTrue(FilterOperator.equal.requiresValue)
        XCTAssertTrue(FilterOperator.between.requiresSecondValue)
        XCTAssertTrue(FilterOperator.inList.isListOperator)
    }

    func testIncompleteConditionDetection() {
        let between = FilterCondition(column: "a", op: .between, value: "1", secondValue: "")
        XCTAssertTrue(between.isIncomplete)
        let complete = FilterCondition(column: "a", op: .between, value: "1", secondValue: "2")
        XCTAssertFalse(complete.isIncomplete)
    }

    // MARK: 枚举展示名

    func testDisplayNamesAreChinese() {
        XCTAssertEqual(ConnectionColor.none.displayName, "无色")
        XCTAssertEqual(SSHAuthMethod.password.displayName, "使用密码")
        XCTAssertEqual(FilterOperator.greaterThanOrEqual.displayName, "大于等于")
        XCTAssertEqual(FilterCombination.any.displayName, "满足任一")
    }
}
