import XCTest
@testable import TableLite

/// 暂存变更的 SQL 生成：INSERT / UPDATE / DELETE、原值定位、语句顺序、NULL 处理。
///
/// 见 `docs/tech-designs/08-pending-changes.md` §3。
final class PendingChangeSQLTests: XCTestCase {

    private let columns: [ColumnInfo] = [
        TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63),
        TestSupport.column("name", type: .varString),
        TestSupport.column("age", type: .long, charset: 63),
        TestSupport.column("bio", type: .blob, charset: 63, dataType: "text"),
    ]

    private var locator: RowLocator { TestSupport.locator(id: "5") }

    // MARK: INSERT

    func testInsertWithNoEditsUsesServerDefaults() {
        let sql = PendingChangeSQL.insertStatement(
            table: "`db`.`t`",
            edits: [],
            columns: columns
        )
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` () VALUES ()")
    }

    func testInsertOrdersColumnsByTableDefinition() {
        let sql = PendingChangeSQL.insertStatement(
            table: "`db`.`t`",
            edits: [TestSupport.edit("age", .text("30")), TestSupport.edit("name", .text("张三"))],
            columns: columns
        )
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` (`name`, `age`) VALUES ('张三', 30)")
    }

    // MARK: UPDATE

    func testUpdateUsesFrozenOriginalLocator() {
        let sql = try! PendingChangeSQL.updateStatement(
            table: "`db`.`t`",
            edits: [TestSupport.edit("name", .text("新")), TestSupport.edit("age", .text("31"))],
            locator: locator,
            columns: columns
        )
        XCTAssertEqual(sql, "UPDATE `db`.`t` SET `name` = '新', `age` = 31 WHERE `id` = 5")
    }

    func testUpdateWithNullLocatorKeyUsesIsNull() {
        let locator = RowLocator(keys: [
            RowKeyValue(column: "name", value: .null, fieldType: .varString),
        ])
        let sql = try! PendingChangeSQL.updateStatement(
            table: "`db`.`t`",
            edits: [TestSupport.edit("age", .text("1"))],
            locator: locator,
            columns: columns
        )
        XCTAssertEqual(sql, "UPDATE `db`.`t` SET `age` = 1 WHERE `name` IS NULL")
    }

    func testUpdateWithEmptyEditsThrows() {
        XCTAssertThrowsError(
            try PendingChangeSQL.updateStatement(
                table: "`db`.`t`",
                edits: [],
                locator: locator,
                columns: columns
            )
        ) { error in
            XCTAssertEqual(error as? PendingChangeSQLError, .emptyUpdateEdits)
        }
    }

    // MARK: DELETE

    func testDeleteUsesLocator() {
        let sql = try! PendingChangeSQL.deleteStatement(table: "`db`.`t`", locator: locator)
        XCTAssertEqual(sql, "DELETE FROM `db`.`t` WHERE `id` = 5")
    }

    func testEmptyLocatorThrows() {
        XCTAssertThrowsError(
            try PendingChangeSQL.locationClause(RowLocator(keys: []))
        ) { error in
            XCTAssertEqual(error as? PendingChangeSQLError, .emptyLocator(.update))
        }
    }

    // MARK: 语句顺序

    func testStatementOrderIsInsertUpdateDelete() {
        let id = UUID()
        let changes: [PendingChange] = [
            .deletion(locator: TestSupport.locator(id: "9")),
            .update(locator: locator, edits: [TestSupport.edit("name", .text("x"))]),
            .insertion(id: id, edits: [TestSupport.edit("name", .text("n"))]),
        ]
        let statements = try! PendingChangeSQL.statements(
            for: changes,
            database: "db",
            table: "t",
            columns: columns
        )
        XCTAssertEqual(statements.count, 3)
        XCTAssertTrue(statements[0].hasPrefix("INSERT INTO"))
        XCTAssertTrue(statements[1].hasPrefix("UPDATE"))
        XCTAssertTrue(statements[2].hasPrefix("DELETE FROM"))
    }

    func testStoreBasedGenerationMatchesPreview() {
        var store = PendingChangeStore()
        store.apply(.editCell(
            row: .existing(locator),
            column: "name",
            value: .text("新"),
            originalValue: .text("旧")
        ))
        let statements = try! PendingChangeSQL.statements(
            for: store,
            database: "db",
            table: "t",
            columns: columns
        )
        XCTAssertEqual(statements, ["UPDATE `db`.`t` SET `name` = '新' WHERE `id` = 5"])
    }

    // MARK: NULL 与二进制

    func testNullValueInUpdate() {
        let sql = try! PendingChangeSQL.updateStatement(
            table: "`db`.`t`",
            edits: [TestSupport.edit("name", .null)],
            locator: locator,
            columns: columns
        )
        XCTAssertEqual(sql, "UPDATE `db`.`t` SET `name` = NULL WHERE `id` = 5")
    }

    func testBinaryValueInInsert() {
        let sql = PendingChangeSQL.insertStatement(
            table: "`db`.`t`",
            edits: [PendingEdit(column: "bio", value: .binary(Data([0xDE, 0xAD])))],
            columns: columns
        )
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` (`bio`) VALUES (0xDEAD)")
    }
}
