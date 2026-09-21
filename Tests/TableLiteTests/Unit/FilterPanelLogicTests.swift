import XCTest
@testable import TableLite

/// `FilterPanelLogic` 的纯函数边界。
/// 覆盖 docs/tech-designs/09-filtering.md §1 §2、specs/05-filtering.md §1 §2。
final class FilterPanelLogicTests: XCTestCase {

    // MARK: - 测试数据

    private func column(_ name: String,
                        dataType: String = "varchar",
                        rawTypeText: String? = nil,
                        pk: Bool = false,
                        invisible: Bool = false) -> TableColumn {
        TableColumn(
            name: name,
            dataType: dataType,
            rawTypeText: rawTypeText ?? dataType,
            isPrimaryKey: pk,
            isInvisible: invisible
        )
    }

    private var enumColumn: TableColumn {
        TableColumn(name: "status", dataType: "enum", rawTypeText: "enum('active','deleted')")
    }

    private var setColumn: TableColumn {
        TableColumn(name: "tags", dataType: "set", rawTypeText: "set('a','b')")
    }

    private var boolColumn: TableColumn {
        TableColumn(name: "flag", dataType: "tinyint", rawTypeText: "tinyint(1)")
    }

    private func condition(_ column: String,
                           _ op: FilterOperator,
                           _ value: String = "",
                           second: String = "",
                           enabled: Bool = true) -> FilterCondition {
        FilterCondition(enabled: enabled, column: column, op: op, value: value, secondValue: second)
    }

    // MARK: - 值输入可见性

    func testValueFieldForOperators() {
        XCTAssertEqual(FilterPanelLogic.valueField(for: .isNull), .none)
        XCTAssertEqual(FilterPanelLogic.valueField(for: .isNotNull), .none)
        XCTAssertEqual(FilterPanelLogic.valueField(for: .equal), .single)
        XCTAssertEqual(FilterPanelLogic.valueField(for: .inList), .single)
        XCTAssertEqual(FilterPanelLogic.valueField(for: .between), .double)
    }

    // MARK: - ENUM / SET / tinyint(1) 候选

    func testValueOptionsForEnumAndSet() {
        XCTAssertEqual(FilterPanelLogic.valueOptions(for: enumColumn), ["active", "deleted"])
        XCTAssertEqual(FilterPanelLogic.valueOptions(for: setColumn), ["a", "b"])
    }

    func testValueOptionsForTinyInt1() {
        XCTAssertEqual(FilterPanelLogic.valueOptions(for: boolColumn), ["0", "1"])
    }

    func testValueOptionsForPlainTextIsNil() {
        XCTAssertNil(FilterPanelLogic.valueOptions(for: column("name")))
    }

    func testValueOptionsForEnumWithoutValuesIsNil() {
        let broken = TableColumn(name: "broken",
                                 dataType: "enum",
                                 rawTypeText: "enum()",
                                 kind: .enumType,
                                 enumValues: nil)
        XCTAssertNil(FilterPanelLogic.valueOptions(for: broken))
    }

    func testUsesValuePicker() {
        XCTAssertTrue(FilterPanelLogic.usesValuePicker(op: .equal, column: enumColumn))
        XCTAssertTrue(FilterPanelLogic.usesValuePicker(op: .between, column: boolColumn))
        // 在列表要写逗号分隔的多个值，始终文本输入。
        XCTAssertFalse(FilterPanelLogic.usesValuePicker(op: .inList, column: enumColumn))
        XCTAssertFalse(FilterPanelLogic.usesValuePicker(op: .equal, column: column("name")))
        XCTAssertFalse(FilterPanelLogic.usesValuePicker(op: .equal, column: nil))
    }

    // MARK: - 条件增删改

    func testDefaultColumnSkipsInvisible() {
        let columns = [
            column("secret", invisible: true),
            column("id", dataType: "int", pk: true),
            column("name"),
        ]
        XCTAssertEqual(FilterPanelLogic.defaultColumn(columns: columns), "id")
    }

    func testDefaultColumnEmptyWhenNoColumns() {
        XCTAssertEqual(FilterPanelLogic.defaultColumn(columns: []), "")
    }

    func testAppendRemoveReplace() {
        let first = condition("name", .equal, "A")
        let filter = FilterPanelLogic.appendingCondition(first, to: FilterSet())
        XCTAssertEqual(filter.conditions.count, 1)

        let second = condition("age", .equal, "18")
        let appended = FilterPanelLogic.appendingCondition(second, to: filter)
        XCTAssertEqual(appended.conditions.map(\.column), ["name", "age"])

        let removed = FilterPanelLogic.removingCondition(id: first.id, from: appended)
        XCTAssertEqual(removed.conditions.map(\.column), ["age"])

        var edited = second
        edited.value = "20"
        let replaced = FilterPanelLogic.replacingCondition(edited, in: appended)
        XCTAssertEqual(replaced.conditions.last?.value, "20")
        XCTAssertEqual(FilterPanelLogic.condition(id: second.id, in: replaced)?.value, "20")
    }

    func testReplaceUnknownConditionAppends() {
        let existing = condition("name", .equal, "A")
        let unknown = condition("age", .equal, "1")
        let result = FilterPanelLogic.replacingCondition(
            unknown,
            in: FilterSet(conditions: [existing])
        )
        XCTAssertEqual(result.conditions.count, 2)
        XCTAssertEqual(result.conditions.last?.id, unknown.id)
    }

    func testInsertingConditionAfterAnchor() {
        let first = condition("name", .equal, "A")
        let third = condition("age", .equal, "18")
        let middle = condition("status", .equal, "active")
        let filter = FilterSet(conditions: [first, third])
        let inserted = FilterPanelLogic.insertingCondition(middle, after: first.id, in: filter)
        XCTAssertEqual(inserted.conditions.map(\.column), ["name", "status", "age"])
    }

    func testInsertingConditionWithoutAnchorAppends() {
        let first = condition("name", .equal, "A")
        let second = condition("age", .equal, "18")
        let filter = FilterSet(conditions: [first])
        let inserted = FilterPanelLogic.insertingCondition(second, after: nil, in: filter)
        XCTAssertEqual(inserted.conditions.map(\.column), ["name", "age"])
        let appended = FilterPanelLogic.insertingCondition(second, after: UUID(), in: filter)
        XCTAssertEqual(appended.conditions.map(\.column), ["name", "age"])
    }

    // MARK: - 高级 / 条件互斥

    func testSwitchingToRawSQLClearsConditions() {
        let filter = FilterSet(conditions: [condition("name", .equal, "A")], rawSQL: "id = 1")
        let raw = FilterPanelLogic.switchingToRawSQL(filter)
        XCTAssertTrue(raw.useRawSQL)
        XCTAssertTrue(raw.conditions.isEmpty)
        XCTAssertEqual(raw.rawSQL, "id = 1")
    }

    func testSwitchingToConditionsClearsRaw() {
        var filter = FilterSet(conditions: [condition("name", .equal, "A")])
        filter.useRawSQL = true
        filter.rawSQL = "id = 1"
        let conditions = FilterPanelLogic.switchingToConditions(filter)
        XCTAssertFalse(conditions.useRawSQL)
        XCTAssertEqual(conditions.rawSQL, "")
        XCTAssertEqual(conditions.conditions.count, 1)
    }

    // MARK: - 列过滤器：至少保留一列

    func testCanApplyColumnFilterRequiresVisibleColumn() {
        let columns = [column("id", dataType: "int", pk: true), column("name")]
        XCTAssertTrue(FilterPanelLogic.canApplyColumnFilter(hidden: [], columns: columns))
        XCTAssertTrue(FilterPanelLogic.canApplyColumnFilter(hidden: ["name"], columns: columns))
        XCTAssertFalse(FilterPanelLogic.canApplyColumnFilter(hidden: ["id", "name"], columns: columns))
    }

    func testCanApplyColumnFilterIgnoresInvisibleColumns() {
        let columns = [
            column("id", dataType: "int", pk: true),
            column("hidden_by_structure", invisible: true),
        ]
        // 结构上不可见的列不参与「至少一列」判定。
        XCTAssertTrue(FilterPanelLogic.canApplyColumnFilter(hidden: ["hidden_by_structure"], columns: columns))
        XCTAssertFalse(FilterPanelLogic.canApplyColumnFilter(hidden: ["id", "hidden_by_structure"], columns: columns))
    }

    func testCanApplyColumnFilterWithNoSelectableColumns() {
        let columns = [column("api_only", invisible: true)]
        XCTAssertTrue(FilterPanelLogic.canApplyColumnFilter(hidden: ["api_only"], columns: columns))
    }

    func testSanitizedHiddenColumnsDropsUnknown() {
        let columns = [column("id", dataType: "int", pk: true), column("name")]
        let sanitized = FilterPanelLogic.sanitizedHiddenColumns(["name", "gone"], columns: columns)
        XCTAssertEqual(sanitized, ["name"])
    }

    func testSearchColumns() {
        let columns = [column("id", dataType: "int"), column("Name"), column("created_at")]
        XCTAssertEqual(FilterPanelLogic.searchColumns(columns, query: "").count, 3)
        XCTAssertEqual(FilterPanelLogic.searchColumns(columns, query: "name").map(\.name), ["Name"])
        XCTAssertEqual(FilterPanelLogic.searchColumns(columns, query: "  at ").map(\.name), ["created_at"])
    }

    // MARK: - issue → 行高亮

    func testHighlightedConditionIDs() {
        let first = condition("name", .equal, "A")
        let second = condition("age", .equal, "18")
        let filter = FilterSet(conditions: [first, second])
        let result = FilterPanelLogic.validate(
            filter,
            columns: [column("name")],
            using: .conservative
        )
        // age 列不存在 → 只高亮第二条。
        XCTAssertEqual(FilterPanelLogic.highlightedConditionIDs(for: result.issues), [second.id])
    }

    func testIssueMessagesDedupesPreservingOrder() {
        let issues = [
            FilterIssue(conditionID: UUID(), message: "缺值"),
            FilterIssue(conditionID: UUID(), message: "缺值"),
            FilterIssue(conditionID: UUID(), message: "找不到列"),
        ]
        XCTAssertEqual(FilterPanelLogic.issueMessages(for: issues), ["缺值", "找不到列"])
    }

    func testIssueMessagesWithOrdinalPointsAtCondition() {
        let first = condition("name", .equal, "A")
        let second = condition("statuz", .equal, "x")
        let filter = FilterSet(conditions: [first, second])
        let result = FilterPanelLogic.validate(
            filter,
            columns: [column("name")],
            using: .conservative
        )
        let messages = FilterPanelLogic.issueMessages(for: result.issues, in: filter)
        XCTAssertEqual(messages, ["第 2 条条件：找不到列「statuz」"])
    }

    func testIssueMessagesWithOrdinalFallsBackWhenConditionGone() {
        let orphan = FilterIssue(conditionID: UUID(), message: "找不到列「x」")
        let messages = FilterPanelLogic.issueMessages(for: [orphan], in: FilterSet())
        XCTAssertEqual(messages, ["找不到列「x」"])
    }

    func testValidateValidConditionProducesSQL() {
        let filter = FilterSet(conditions: [condition("name", .equal, "Alice")])
        let result = FilterPanelLogic.validate(
            filter,
            columns: [column("name")],
            using: .conservative
        )
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.sql, "(`name` = 'Alice')")
    }
}
