import XCTest
@testable import TableLite

/// SQL 生成的精确文本与顺序。见 docs/tech-designs/08-pending-changes.md §3。
/// 全部走 `SQLValueLiteral` 与 `SQLIdentifier`，不做手工拼接。
final class PendingSQLBuilderTests: XCTestCase {

    private let literalizer = SQLValueLiteralizer.conservative
    private let row1 = RowIdentity.existing("1")
    private let row2 = RowIdentity.existing("2")

    private func idLocator(_ value: String) -> RowLocator {
        PendingTestFixtures.locator(["id"], [.text(value)])
    }

    // MARK: INSERT

    func testInsertOnlyContainsFilledColumns() {
        var engine = PendingTestFixtures.engine()
        let inserted = engine.beginInsert()
        engine.setInsertValue(row: inserted, column: "name", value: .text("赵六"))

        let statements = engine.sqlStatements(using: literalizer)
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].text,
                       "INSERT INTO `app_dev`.`users` (`name`) VALUES ('赵六')")
        XCTAssertEqual(statements[0].kind, .insert)
        XCTAssertEqual(statements[0].identity, inserted)
    }

    func testEmptyInsertUsesDefaultValues() {
        var engine = PendingTestFixtures.engine()
        _ = engine.beginInsert()

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "INSERT INTO `app_dev`.`users` () VALUES ()")
    }

    func testInsertNullCountsAsFilled() {
        var engine = PendingTestFixtures.engine()
        let inserted = engine.beginInsert()
        engine.setInsertValue(row: inserted, column: "email", value: .null)

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "INSERT INTO `app_dev`.`users` (`email`) VALUES (NULL)")
    }

    func testInsertColumnsFollowTableOrder() {
        var engine = PendingTestFixtures.engine()
        let inserted = engine.beginInsert()
        // 先填 email 再填 name，输出仍按表列顺序 name → email
        engine.setInsertValue(row: inserted, column: "email", value: .text("e"))
        engine.setInsertValue(row: inserted, column: "name", value: .text("n"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "INSERT INTO `app_dev`.`users` (`name`, `email`) VALUES ('n', 'e')")
    }

    // MARK: UPDATE

    func testUpdateSetFollowsTableColumnOrder() throws {
        var engine = PendingTestFixtures.engine()
        // 先改 email 再改 name
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "email",
                             originalValue: .text("e0"), newValue: .text("e"))
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "name",
                             originalValue: .text("n0"), newValue: .text("n"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "UPDATE `app_dev`.`users` SET `name` = 'n', `email` = 'e' WHERE `id` = 1")
    }

    func testUpdateWhereUsesFrozenLocator() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row1, locator: idLocator("42"), column: "name",
                             originalValue: .text("a"), newValue: .text("b"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "UPDATE `app_dev`.`users` SET `name` = 'b' WHERE `id` = 42")
    }

    func testEditingPrimaryKeySetsNewValueAndWhereUsesOldValue() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row1, locator: idLocator("5"), column: "id",
                             originalValue: .text("5"), newValue: .text("6"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "UPDATE `app_dev`.`users` SET `id` = 6 WHERE `id` = 5")
    }

    func testCompositePrimaryKeyUsesAndAndIsNull() throws {
        let columns = [
            PendingTestFixtures.column("id1", "int", pk: true, nullable: false),
            PendingTestFixtures.column("id2", "int", pk: true, nullable: false),
            PendingTestFixtures.column("value", "varchar", rawType: "varchar(255)"),
        ]
        var engine = PendingTestFixtures.engine(columns: columns)
        let locator = PendingTestFixtures.locator(["id1", "id2"], [.text("1"), .null])
        try engine.applyEdit(row: row1, locator: locator, column: "value",
                             originalValue: .text("old"), newValue: .text("new"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "UPDATE `app_dev`.`users` SET `value` = 'new' WHERE `id1` = 1 AND `id2` IS NULL")
    }

    // MARK: DELETE

    func testDeleteUsesLocator() {
        var engine = PendingTestFixtures.engine()
        engine.applyDelete(row: row1, locator: idLocator("7"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "DELETE FROM `app_dev`.`users` WHERE `id` = 7")
    }

    func testDeleteWithCompositeKeyAndNull() {
        let columns = [
            PendingTestFixtures.column("id1", "int", pk: true, nullable: false),
            PendingTestFixtures.column("id2", "int", pk: true, nullable: false),
        ]
        var engine = PendingTestFixtures.engine(columns: columns)
        engine.applyDelete(
            row: row1,
            locator: PendingTestFixtures.locator(["id1", "id2"], [.text("3"), .null])
        )

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "DELETE FROM `app_dev`.`users` WHERE `id1` = 3 AND `id2` IS NULL")
    }

    // MARK: 顺序与编号

    func testStatementsAreOrderedInsertUpdateDelete() throws {
        var engine = PendingTestFixtures.engine()
        // 故意按 update → insert → delete 的操作顺序
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "name",
                             originalValue: .text("a"), newValue: .text("b"))
        _ = engine.beginInsert()
        engine.applyDelete(row: row2, locator: idLocator("2"))

        let statements = engine.sqlStatements(using: literalizer)
        XCTAssertEqual(statements.map(\.kind), [.insert, .update, .delete])
    }

    func testInsertOrderFollowsOperationOrder() {
        var engine = PendingTestFixtures.engine()
        let first = engine.beginInsert()
        engine.setInsertValue(row: first, column: "name", value: .text("first"))
        let second = engine.beginInsert()
        engine.setInsertValue(row: second, column: "name", value: .text("second"))

        let texts = engine.sqlStatements(using: literalizer).map(\.text)
        XCTAssertTrue(texts[0].contains("'first'"))
        XCTAssertTrue(texts[1].contains("'second'"))
    }

    func testUpdateOrderFollowsOperationOrder() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "name",
                             originalValue: .text("a"), newValue: .text("one"))
        try engine.applyEdit(row: row2, locator: idLocator("2"), column: "name",
                             originalValue: .text("c"), newValue: .text("two"))

        let statements = engine.sqlStatements(using: literalizer)
        XCTAssertEqual(statements[0].identity, row1)
        XCTAssertEqual(statements[1].identity, row2)
    }

    func testStatementIDsAreSequentialFromOne() throws {
        var engine = PendingTestFixtures.engine()
        _ = engine.beginInsert()
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "name",
                             originalValue: .text("a"), newValue: .text("b"))
        engine.applyDelete(row: row2, locator: idLocator("2"))

        let statements = engine.sqlStatements(using: literalizer)
        XCTAssertEqual(statements.map(\.id), [1, 2, 3])
    }

    // MARK: 大字段安全（硬约束）

    func testUneditedLargeFieldNeverEntersSet() throws {
        let columns = [
            PendingTestFixtures.column("id", "int", pk: true, nullable: false),
            PendingTestFixtures.column("name", "varchar", rawType: "varchar(255)"),
            PendingTestFixtures.column("body", "longtext"),
        ]
        var engine = PendingTestFixtures.engine(columns: columns)
        // 只改 name；body 在网格里是截断值，绝不能写回
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "name",
                             originalValue: .text("old"), newValue: .text("new"))

        let sql = engine.sqlStatements(using: literalizer).first?.text ?? ""
        XCTAssertFalse(sql.contains("body"), "未编辑的截断大字段不应出现在 SET 里：\(sql)")
        XCTAssertEqual(sql, "UPDATE `app_dev`.`users` SET `name` = 'new' WHERE `id` = 1")
    }

    // MARK: 字面量

    func testConservativeLiteralizerEscapesQuoteAndBackslash() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "name",
                             originalValue: .text("old"), newValue: .text("O'Brien\\path"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       #"UPDATE `app_dev`.`users` SET `name` = 'O\'Brien\\path' WHERE `id` = 1"#)
    }

    func testNumericLookingTextValueIsQuoted() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "name",
                             originalValue: .text("a"), newValue: .text("42"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "UPDATE `app_dev`.`users` SET `name` = '42' WHERE `id` = 1")
    }

    func testIntegerLocatorIsUnquoted() {
        var engine = PendingTestFixtures.engine()
        engine.applyDelete(row: row1, locator: idLocator("100"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "DELETE FROM `app_dev`.`users` WHERE `id` = 100")
    }

    func testIdentifierQuotingEscapesBackticks() throws {
        let columns = [
            PendingTestFixtures.column("id", "int", pk: true, nullable: false),
            PendingTestFixtures.column("we`ird", "varchar", rawType: "varchar(10)"),
        ]
        var engine = PendingTestFixtures.engine(columns: columns)
        try engine.applyEdit(row: row1, locator: idLocator("1"), column: "we`ird",
                             originalValue: .text("a"), newValue: .text("b"))

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "UPDATE `app_dev`.`users` SET `we``ird` = 'b' WHERE `id` = 1")
    }

    func testNullableLocatorValueUsesIsNull() {
        let columns = [
            PendingTestFixtures.column("id", "int", pk: true, nullable: false),
            PendingTestFixtures.column("code", "varchar", rawType: "varchar(10)", pk: true),
        ]
        var engine = PendingTestFixtures.engine(columns: columns)
        engine.applyDelete(
            row: row1,
            locator: PendingTestFixtures.locator(["id", "code"], [.text("1"), .null])
        )

        XCTAssertEqual(engine.sqlStatements(using: literalizer).first?.text,
                       "DELETE FROM `app_dev`.`users` WHERE `id` = 1 AND `code` IS NULL")
    }

    // MARK: 空暂存

    func testEmptyEngineProducesNoStatements() {
        let engine = PendingTestFixtures.engine()
        XCTAssertTrue(engine.sqlStatements(using: literalizer).isEmpty)
    }
}
