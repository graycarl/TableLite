import Foundation

// MARK: - 过滤器面板纯逻辑
//
// 只放不依赖 SwiftUI / IO 的纯函数：条件增删改、值输入可见性、ENUM 候选、
// 列过滤器的「至少保留一列」、以及 issue → 条件行高亮映射。
//
// 设计依据：docs/tech-designs/09-filtering.md §1 §2、specs/05-filtering.md §1 §2。
// 状态真源是 `TableDataViewModel.filter`（`FilterSet`），这里不持有任何状态。

enum FilterPanelLogic {

    // MARK: - 条件编辑

    /// 新建一条条件的默认值。
    static func makeCondition(column: String = "", op: FilterOperator = .equal) -> FilterCondition {
        FilterCondition(column: column, op: op)
    }

    /// 新条件默认选中的列：第一个结构上可见的列；没有可选项时返回空串。
    static func defaultColumn(columns: [TableColumn]) -> String {
        columns.first(where: { !$0.isInvisible })?.name ?? ""
    }

    /// 追加一条条件（保持顺序）。
    static func appendingCondition(_ condition: FilterCondition, to filter: FilterSet) -> FilterSet {
        var next = filter
        next.conditions.append(condition)
        return next
    }

    /// 在锚点条件之后插入；找不到锚点时追加到末尾。
    static func insertingCondition(_ condition: FilterCondition,
                                   after id: UUID?,
                                   in filter: FilterSet) -> FilterSet {
        var next = filter
        if let id, let index = next.conditions.firstIndex(where: { $0.id == id }) {
            next.conditions.insert(condition, at: index + 1)
        } else {
            next.conditions.append(condition)
        }
        return next
    }

    static func removingCondition(id: UUID, from filter: FilterSet) -> FilterSet {
        var next = filter
        next.conditions.removeAll { $0.id == id }
        return next
    }

    /// 按 id 替换；找不到时追加，保证调用方不会静默丢条件。
    static func replacingCondition(_ condition: FilterCondition, in filter: FilterSet) -> FilterSet {
        var next = filter
        if let index = next.conditions.firstIndex(where: { $0.id == condition.id }) {
            next.conditions[index] = condition
        } else {
            next.conditions.append(condition)
        }
        return next
    }

    static func condition(id: UUID, in filter: FilterSet) -> FilterCondition? {
        filter.conditions.first { $0.id == id }
    }

    // MARK: - 值输入可见性

    /// 一条条件需要几个值输入框。
    enum ValueField: Equatable {
        case none
        case single
        case double
    }

    static func valueField(for op: FilterOperator) -> ValueField {
        guard op.requiresValue else { return .none }
        return op.requiresSecondValue ? .double : .single
    }

    /// 值输入的固定候选：
    /// - `tinyint(1)` → ["0", "1"]（specs/05 §1「ENUM / SET / 布尔列」）；
    /// - ENUM / SET → 列定义里的取值；
    /// - 其余返回 nil，走自由文本。
    static func valueOptions(for column: TableColumn) -> [String]? {
        if column.isTinyInt1 { return ["0", "1"] }
        switch column.kind {
        case .enumType, .setType:
            guard let values = column.enumValues, !values.isEmpty else { return nil }
            return values
        default:
            return nil
        }
    }

    /// 值输入是否用下拉。`在列表中` 要写逗号分隔的多个值，始终用文本。
    static func usesValuePicker(op: FilterOperator, column: TableColumn?) -> Bool {
        guard op != .inList, let column else { return false }
        return valueOptions(for: column) != nil
    }

    // MARK: - 高级 / 条件行互斥

    /// 切到高级模式：保留已写的原始片段，清空条件行（specs/05 §1）。
    static func switchingToRawSQL(_ filter: FilterSet) -> FilterSet {
        var next = filter
        next.useRawSQL = true
        next.conditions = []
        return next
    }

    /// 切回条件行模式：清空原始 WHERE 片段。
    static func switchingToConditions(_ filter: FilterSet) -> FilterSet {
        var next = filter
        next.useRawSQL = false
        next.rawSQL = ""
        return next
    }

    // MARK: - 列过滤器

    /// 可参与显隐的可选列（排除结构上不可见的列）。
    static func selectableColumns(_ columns: [TableColumn]) -> [TableColumn] {
        columns.filter { !$0.isInvisible }
    }

    /// 至少保留一列可见（specs/05 §2）。没有任何可选列时视为可应用。
    static func canApplyColumnFilter(hidden: Set<String>, columns: [TableColumn]) -> Bool {
        let selectable = selectableColumns(columns).map(\.name)
        guard !selectable.isEmpty else { return true }
        return !selectable.allSatisfy { hidden.contains($0) }
    }

    /// 落盘前清理：只保留结构里真实存在的列，避免结构变化后残留隐藏项。
    static func sanitizedHiddenColumns(_ hidden: Set<String>, columns: [TableColumn]) -> Set<String> {
        hidden.intersection(Set(selectableColumns(columns).map(\.name)))
    }

    /// 列过滤浮层的搜索：大小写不敏感，空查询返回全部。
    static func searchColumns(_ columns: [TableColumn], query: String) -> [TableColumn] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return columns }
        return columns.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    // MARK: - 应用校验 / issue → 行高亮

    /// 生成 WHERE 片段并返回 issues（列不存在、缺值等）。
    /// 值一律经 `SQLValueLiteral` 转义，见 docs/tech-designs/09-filtering.md §1.4。
    static func validate(_ filter: FilterSet,
                         columns: [TableColumn],
                         using literalizer: SQLValueLiteralizer) -> FilterSQLBuilder.Result {
        FilterSQLBuilder.build(filter, columns: columns, using: literalizer)
    }

    /// issue → 需要高亮的条件行 id。
    static func highlightedConditionIDs(for issues: [FilterIssue]) -> Set<UUID> {
        Set(issues.map(\.conditionID))
    }

    /// 去重后的问题文案（保持首次出现顺序）。
    static func issueMessages(for issues: [FilterIssue]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for issue in issues where seen.insert(issue.message).inserted {
            output.append(issue.message)
        }
        return output
    }

    /// 带条件序号的文案：「第 N 条条件：找不到列「x」」，方便用户定位。
    static func issueMessages(for issues: [FilterIssue], in filter: FilterSet) -> [String] {
        var ordinalByID: [UUID: Int] = [:]
        for (index, condition) in filter.conditions.enumerated() {
            ordinalByID[condition.id] = index + 1
        }
        var seen = Set<String>()
        var output: [String] = []
        for issue in issues {
            let text: String
            if let ordinal = ordinalByID[issue.conditionID] {
                text = "第 \(ordinal) 条条件：\(issue.message)"
            } else {
                text = issue.message
            }
            if seen.insert(text).inserted { output.append(text) }
        }
        return output
    }
}
