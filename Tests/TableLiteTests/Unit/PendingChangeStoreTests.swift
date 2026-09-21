import XCTest
@testable import TableLite

/// 暂存区合并规则与可编辑性判定。
///
/// 见 `docs/tech-designs/08-pending-changes.md` §2.2、§7。
final class PendingChangeStoreTests: XCTestCase {

    private let existing = RowIdentity.existing(TestSupport.locator())

    // MARK: 合并规则

    func testEditCreatesUpdate() {
        var store = PendingChangeStore()
        let outcome = store.apply(.editCell(
            row: existing, column: "name", value: .text("张三"), originalValue: .text("旧")
        ))
        XCTAssertEqual(outcome, .created(.update))
        XCTAssertEqual(store.totalCount, 1)
        XCTAssertEqual(store.changes[0].edits, [TestSupport.edit("name", .text("张三"))])
    }

    func testEditingSecondColumnMerges() {
        var store = PendingChangeStore()
        store.apply(.editCell(row: existing, column: "name", value: .text("张三"), originalValue: .text("旧")))
        let outcome = store.apply(.editCell(row: existing, column: "age", value: .text("30"), originalValue: .text("20")))
        XCTAssertEqual(outcome, .merged(.update))
        XCTAssertEqual(store.totalCount, 1)
        XCTAssertEqual(store.changes[0].edits.count, 2)
    }

    func testRevertingColumnRemovesChange() {
        var store = PendingChangeStore()
        store.apply(.editCell(row: existing, column: "name", value: .text("张三"), originalValue: .text("旧")))
        let outcome = store.apply(.editCell(row: existing, column: "name", value: .text("旧"), originalValue: .text("旧")))
        XCTAssertEqual(outcome, .removed)
        XCTAssertTrue(store.isEmpty)
    }

    func testRevertingOneOfTwoColumnsKeepsUpdate() {
        var store = PendingChangeStore()
        store.apply(.editCell(row: existing, column: "name", value: .text("张三"), originalValue: .text("旧")))
        store.apply(.editCell(row: existing, column: "age", value: .text("30"), originalValue: .text("20")))
        let outcome = store.apply(.editCell(row: existing, column: "name", value: .text("旧"), originalValue: .text("旧")))
        XCTAssertEqual(outcome, .merged(.update))
        XCTAssertEqual(store.changes[0].edits, [TestSupport.edit("age", .text("30"))])
    }

    func testEditWithoutChangeIsNoop() {
        var store = PendingChangeStore()
        let outcome = store.apply(.editCell(row: existing, column: "name", value: .text("旧"), originalValue: .text("旧")))
        XCTAssertEqual(outcome, .noChange)
        XCTAssertTrue(store.isEmpty)
    }

    func testInsertRowThenEditMerges() {
        var store = PendingChangeStore()
        let id = UUID()
        XCTAssertEqual(store.apply(.beginInsertion(id: id)), .insertionCreated)
        let outcome = store.apply(.editCell(
            row: .insertion(id), column: "name", value: .text("新"), originalValue: .null
        ))
        XCTAssertEqual(outcome, .merged(.insert))
        XCTAssertEqual(store.counts.insert, 1)
    }

    func testDeleteInsertedRowRemovesEverything() {
        var store = PendingChangeStore()
        let id = UUID()
        store.apply(.beginInsertion(id: id))
        store.apply(.editCell(row: .insertion(id), column: "name", value: .text("新"), originalValue: .null))
        let outcome = store.apply(.deleteRow(.insertion(id)))
        XCTAssertEqual(outcome, .removed)
        XCTAssertTrue(store.isEmpty)
    }

    func testDeleteExistingUpdateBecomesDelete() {
        var store = PendingChangeStore()
        store.apply(.editCell(row: existing, column: "name", value: .text("新"), originalValue: .text("旧")))
        let outcome = store.apply(.deleteRow(existing))
        XCTAssertEqual(outcome, .replacedByDelete)
        XCTAssertEqual(store.changes.count, 1)
        XCTAssertEqual(store.changes[0].kind, .delete)
    }

    func testEditDeletedRowIsRejected() {
        var store = PendingChangeStore()
        store.apply(.deleteRow(existing))
        let outcome = store.apply(.editCell(row: existing, column: "name", value: .text("x"), originalValue: .text("旧")))
        XCTAssertEqual(outcome, .rejected(.rowDeleted))
    }

    func testDeleteWithoutPriorChange() {
        var store = PendingChangeStore()
        XCTAssertEqual(store.apply(.deleteRow(existing)), .created(.delete))
        XCTAssertEqual(store.changes[0].kind, .delete)
        XCTAssertEqual(store.apply(.deleteRow(existing)), .noChange)
    }

    func testUndoRowRemovesChange() {
        var store = PendingChangeStore()
        store.apply(.deleteRow(existing))
        XCTAssertEqual(store.apply(.undoRow(existing)), .removed)
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.apply(.undoRow(existing)), .noChange)
    }

    func testClearInsertCellRemovesOnlyThatColumn() {
        var store = PendingChangeStore()
        let id = UUID()
        store.apply(.beginInsertion(id: id))
        store.apply(.editCell(row: .insertion(id), column: "name", value: .text("新"), originalValue: .null))
        store.apply(.editCell(row: .insertion(id), column: "age", value: .text("1"), originalValue: .null))
        XCTAssertEqual(store.apply(.clearInsertCell(row: .insertion(id), column: "name")), .merged(.insert))
        XCTAssertEqual(store.changes[0].edits, [TestSupport.edit("age", .text("1"))])
    }

    func testDiscardAll() {
        var store = PendingChangeStore()
        store.apply(.deleteRow(existing))
        XCTAssertEqual(store.apply(.discardAll), .removed)
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.apply(.discardAll), .noChange)
    }

    // MARK: 统计与文案

    func testCountsAndStatusText() {
        var store = PendingChangeStore()
        store.apply(.beginInsertion(id: UUID()))
        store.apply(.editCell(row: existing, column: "a", value: .text("1"), originalValue: .text("0")))
        store.apply(.deleteRow(.existing(TestSupport.locator(id: "9"))))
        let counts = store.counts
        XCTAssertEqual(counts.insert, 1)
        XCTAssertEqual(counts.update, 1)
        XCTAssertEqual(counts.delete, 1)
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(store.statusText, "有 3 处未提交的修改（1 新增 · 1 修改 · 1 删除）")
    }

    // MARK: 定位校验

    func testValidateLocatorsThrowsForEmptyLocator() {
        let change = PendingChange.update(
            locator: RowLocator(keys: []),
            edits: [TestSupport.edit("name", .text("x"))]
        )
        let store = PendingChangeStore(changes: [change])
        XCTAssertThrowsError(try store.validateLocators()) { error in
            XCTAssertEqual(error as? PendingChangeValidationError, .missingLocator(.update))
        }
    }

    func testValidateLocatorsPassesForNormalStore() {
        var store = PendingChangeStore()
        store.apply(.editCell(row: existing, column: "name", value: .text("x"), originalValue: .text("y")))
        XCTAssertNoThrow(try store.validateLocators())
    }

    // MARK: 可编辑性

    func testEditabilityEvaluation() {
        XCTAssertEqual(
            EditabilityEvaluator.evaluate(isView: true, hasPrimaryKey: true, isConnectionReadOnly: false),
            .readOnly(.view)
        )
        XCTAssertEqual(
            EditabilityEvaluator.evaluate(isView: false, hasPrimaryKey: false, isConnectionReadOnly: false),
            .readOnly(.noPrimaryKey)
        )
        XCTAssertEqual(
            EditabilityEvaluator.evaluate(isView: false, hasPrimaryKey: true, isConnectionReadOnly: true),
            .readOnly(.readOnlyConnection)
        )
        XCTAssertEqual(
            EditabilityEvaluator.evaluate(isView: false, hasPrimaryKey: true, isConnectionReadOnly: false),
            .editable
        )
    }

    func testEditableReasonMessages() {
        XCTAssertEqual(UneditableReason.noPrimaryKey.message, "该表没有主键，无法安全定位行")
        XCTAssertEqual(UneditableReason.view.message, "视图不可编辑")
        XCTAssertEqual(UneditableReason.readOnlyConnection.message, "该连接处于只读模式")
    }

    func testPrimaryKeyDetectionIgnoresUniqueIndex() {
        let id = TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey)
        let email = TestSupport.column("email", flags: ColumnFlag.uniqueKey)
        XCTAssertEqual(EditabilityEvaluator.primaryKeyColumns(in: [id, email]).map(\.name), ["id"])
        XCTAssertTrue(EditabilityEvaluator.hasPrimaryKey(in: [id, email]))
        XCTAssertFalse(EditabilityEvaluator.hasPrimaryKey(in: [email]))
    }
}
