import SwiftUI
import os

// MARK: - 过滤器面板状态协调
//
// 过滤器横条的可见性同时被两处驱动：
// - `TableDataTabView`（横条本身）；
// - `StatusBarView`（「筛选 / 列」按钮与 ⌘F / ⌥⌘F）。
//
// 两者是兄弟视图，所以用按标签 id 分桶的共享状态协调。真源仍是
// `TableDataViewModel.filter`，这里只放「横条是否展开 / 焦点请求」这类纯 UI 状态。

@MainActor
final class FilterPanelState: ObservableObject {
    @Published var isFilterBarVisible = false
    /// 每次自增表示「请聚焦过滤器横条」。
    @Published var focusToken = 0
    /// 需要聚焦的条件行 id（「按此列筛选」后聚焦值输入）。
    @Published var focusConditionID: UUID?
}

@MainActor
final class FilterPanelCoordinator {

    static let shared = FilterPanelCoordinator()

    private var states: [UUID: FilterPanelState] = [:]

    private init() {}

    func state(for tabID: UUID) -> FilterPanelState {
        if let existing = states[tabID] { return existing }
        let created = FilterPanelState()
        states[tabID] = created
        return created
    }
}

// MARK: - 过滤器横条
//
// 网格上方的一条可折叠横条。见 docs/tech-designs/09-filtering.md §1、
// specs/05-filtering.md §1。
//
// 状态真源：`model.filter`（`FilterSet`）。本视图不复制过滤状态。
// 「应用」会先用 `FilterSQLBuilder` 校验，再调用 `model.applyFilter` 重新查询。

struct FilterBarView: View {

    @ObservedObject var model: TableDataViewModel
    @Binding var isVisible: Bool
    /// 父视图（状态栏）请求聚焦时自增。
    let focusToken: Int
    /// 需要聚焦的条件行；消费后由本视图置 nil。
    @Binding var focusConditionID: UUID?
    var literalizerProvider: () async -> SQLValueLiteralizer

    @State private var issues: [FilterIssue] = []
    @State private var loadErrorText: String?
    @FocusState private var focusedConditionID: UUID?

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    private var highlighted: Set<UUID> { FilterPanelLogic.highlightedConditionIDs(for: issues) }

    private var hasAnythingToReset: Bool {
        !model.filter.conditions.isEmpty
            || !model.filter.rawSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bannerText: String? {
        let messages = FilterPanelLogic.issueMessages(for: issues, in: model.filter)
        if !messages.isEmpty { return messages.joined(separator: "\n") }
        return loadErrorText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let bannerText {
                banner(bannerText)
            }
            if model.filter.useRawSQL {
                rawEditor
            } else {
                conditionRows
            }
            Divider()
            footer
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand { isVisible = false }
        .onAppear { applyFocusRequest() }
        .onChange(of: focusToken) { _, _ in applyFocusRequest() }
        .onChange(of: focusConditionID) { _, _ in applyFocusRequest() }
        .onChange(of: model.loadError) { _, error in
            loadErrorText = error.map { $0.serverError?.formatted ?? $0.title }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text("过滤器").font(.headline)
            Button {
                addCondition(after: model.filter.conditions.last?.id)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("添加一条条件（⌘I）")
            .disabled(model.filter.useRawSQL)

            Spacer()

            Button {
                isVisible = false
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("收起过滤器（Esc，条件保留）")

            // 面板内的 ⌘I 归「加一条条件」，与网格的「插入新行」不冲突。
            // 高级模式不添加条件，但保留按钮以吞掉 ⌘I，避免落到网格。
            Button("") { addCondition(after: model.filter.conditions.last?.id) }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: 条件行 / 高级模式

    @ViewBuilder
    private var conditionRows: some View {
        if model.filter.conditions.isEmpty {
            Text("没有条件。点左上角 + 或按 ⌘I 添加一条。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach($model.filter.conditions) { $condition in
                        FilterConditionRow(
                            condition: $condition,
                            columns: model.allColumns,
                            isHighlighted: highlighted.contains(condition.id),
                            focusedConditionID: $focusedConditionID,
                            onAdd: { addCondition(after: condition.id) },
                            onRemove: { removeCondition(condition.id) }
                        )
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $model.filter.rawSQL)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 56, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            Text("高级条件不会被校验，请自行确认语法正确")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            if !model.filter.useRawSQL {
                Picker("组合方式", selection: $model.filter.logic) {
                    ForEach(FilterLogic.allCases, id: \.self) { logic in
                        Text(logic.displayName).tag(logic)
                    }
                }
                .pickerStyle(.radioGroup)
                .fixedSize()
            }

            Button(model.filter.useRawSQL ? "返回条件行" : "高级 / 直接写条件") {
                toggleAdvancedMode()
            }
            .help("高级模式与条件行互斥，切换会清空另一侧")

            Spacer()

            Button("重置") { reset() }
                .disabled(!hasAnythingToReset)

            Button("应用") { apply() }
                .keyboardShortcut(.defaultAction)
                .help("按当前条件重新从第 1 页加载")
        }
    }

    // MARK: 动作

    private func addCondition(after id: UUID?) {
        guard !model.filter.useRawSQL else { return }
        let condition = FilterPanelLogic.makeCondition(
            column: FilterPanelLogic.defaultColumn(columns: model.allColumns)
        )
        model.filter = FilterPanelLogic.insertingCondition(condition, after: id, in: model.filter)
        focusedConditionID = condition.id
    }

    private func removeCondition(_ id: UUID) {
        model.filter = FilterPanelLogic.removingCondition(id: id, from: model.filter)
        if focusedConditionID == id { focusedConditionID = nil }
    }

    private func toggleAdvancedMode() {
        model.filter = model.filter.useRawSQL
            ? FilterPanelLogic.switchingToConditions(model.filter)
            : FilterPanelLogic.switchingToRawSQL(model.filter)
        issues = []
        loadErrorText = nil
    }

    private func reset() {
        model.filter = FilterSet()
        issues = []
        loadErrorText = nil
        focusedConditionID = nil
        Task { await model.applyFilter(FilterSet()) }
    }

    private func apply() {
        let filter = model.filter
        Task {
            let literalizer = await literalizerProvider()
            let result = FilterPanelLogic.validate(filter, columns: model.allColumns, using: literalizer)
            guard result.issues.isEmpty else {
                issues = result.issues
                loadErrorText = nil
                logger.notice("过滤器未通过校验：\(result.issues.count) 条问题")
                return
            }
            issues = []
            loadErrorText = nil
            await model.applyFilter(filter)
            if let error = model.loadError {
                loadErrorText = error.serverError?.formatted ?? error.title
            }
        }
    }

    private func applyFocusRequest() {
        if let pending = focusConditionID {
            focusedConditionID = pending
            focusConditionID = nil
            return
        }
        if model.filter.useRawSQL { return }
        if model.filter.conditions.isEmpty {
            addCondition(after: nil)
        } else {
            focusedConditionID = model.filter.conditions.first?.id
        }
    }
}
