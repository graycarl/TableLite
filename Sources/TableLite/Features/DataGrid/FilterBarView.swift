import SwiftUI

/// 行过滤器横条（`specs/05-filtering.md` §1、`docs/tech-designs/09-filtering.md` §1.2）。
///
/// 网格上方的一条可折叠横条：
/// - 每行是「启用勾选 + 列下拉（可搜索）+ 操作符下拉 + 值输入」，支持增删行；
/// - 跨列快速过滤框对所有可见列做 `LIKE`，与条件行 / Raw 并存；
/// - AND / OR 组合、切到 Raw SQL、重置、应用；
/// - `Esc` 关闭但保留条件；`⌘I` 由数据网格转发到「添加条件」。
struct FilterBarView: View {

    let viewModel: TableDataViewModel

    @FocusState private var quickFilterFocused: Bool

    var body: some View {
        if viewModel.isFilterVisible {
            VStack(spacing: 6) {
                quickFilterRow
                if let error = viewModel.filterError {
                    errorBanner(error)
                }
                if viewModel.filterDraft.isRawMode {
                    rawEditor
                } else {
                    conditionList
                }
                footer
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .onExitCommand { viewModel.setFilterVisible(false) }
            .onAppear {
                // ⌘F 打开时把焦点放到快速过滤框。
                if viewModel.filterFocusConditionID == nil {
                    quickFilterFocused = true
                }
            }
            .onChange(of: viewModel.filterFocusToken) { _, _ in
                // 需要聚焦条件值时由对应行自己处理；这里只在聚焦快速过滤框时响应。
                if viewModel.filterFocusConditionID == nil {
                    quickFilterFocused = true
                }
            }
        }
    }

    // MARK: 快速过滤

    private var quickFilterRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("快速过滤：对所有可见列包含…", text: quickFilterBinding)
                .textFieldStyle(.roundedBorder)
                .focused($quickFilterFocused)
                .frame(maxWidth: 360)
                .onSubmit { viewModel.applyQuickFilter() }
            if viewModel.filterDraft.hasQuickFilter {
                Button {
                    viewModel.clearQuickFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("清除快速过滤")
            }
            Spacer()
            Button {
                viewModel.setFilterVisible(false)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("关闭过滤器（条件保留）")
        }
    }

    private var quickFilterBinding: Binding<String> {
        Binding(
            get: { viewModel.filterDraft.quickFilter },
            set: { viewModel.setQuickFilter($0) }
        )
    }

    // MARK: 错误提示

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: 条件行

    private var conditionList: some View {
        VStack(spacing: 4) {
            ForEach(viewModel.filterDraft.conditions) { condition in
                FilterConditionRow(viewModel: viewModel, conditionID: condition.id)
            }
            HStack(spacing: 6) {
                Button {
                    viewModel.addFilterCondition()
                } label: {
                    Label("添加条件", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("i", modifiers: .command)
                .help("添加一行过滤条件（⌘I）")
                Spacer()
            }
        }
    }

    // MARK: Raw 模式

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("WHERE")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("id IN (1, 2, 3) AND status <> 'deleted'", text: rawWhereBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .font(.system(.callout, design: .monospaced))
            }
            Text("高级条件不会被校验，请自行确认语法正确。与条件行互斥，切换会清空条件行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rawWhereBinding: Binding<String> {
        Binding(
            get: { viewModel.filterDraft.rawWhere },
            set: { viewModel.setRawWhere($0) }
        )
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack(spacing: 10) {
            if viewModel.filterDraft.isRawMode {
                Button("切换回条件行") { viewModel.switchFilterToConditionsMode() }
                    .buttonStyle(.borderless)
            } else {
                Picker("组合方式", selection: combinationBinding) {
                    ForEach(FilterCombination.allCases, id: \.self) { combination in
                        Text(combination.displayName).tag(combination)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                Button("高级 / 直接写条件") { viewModel.switchFilterToRawMode() }
                    .buttonStyle(.borderless)
            }
            Spacer()
            Button("重置") { viewModel.resetFilter() }
            Button("应用") { viewModel.applyFilter() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var combinationBinding: Binding<FilterCombination> {
        Binding(
            get: { viewModel.filterDraft.combination },
            set: { viewModel.setFilterCombination($0) }
        )
    }
}

// MARK: - 单条条件行

/// 一行「启用勾选 + 列 + 操作符 + 值」。
private struct FilterConditionRow: View {

    let viewModel: TableDataViewModel
    let conditionID: UUID

    @FocusState private var valueFocused: Bool

    private var condition: FilterCondition? {
        viewModel.filterDraft.conditions.first { $0.id == conditionID }
    }

    var body: some View {
        if let condition {
            HStack(spacing: 6) {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("是否参与过滤")

                ColumnPickerButton(
                    columns: viewModel.columns,
                    selected: condition.column,
                    onSelect: { viewModel.setFilterConditionColumn(id: conditionID, column: $0) }
                )
                .frame(width: 170)

                Picker("操作符", selection: operatorBinding) {
                    ForEach(FilterOperator.allCases, id: \.self) { op in
                        Text(op.displayName).tag(op)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)

                valueEditor(condition)
                    .frame(maxWidth: 320)

                Button {
                    viewModel.addFilterCondition()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加条件（⌘I）")

                Button {
                    viewModel.removeFilterCondition(id: conditionID)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("删除这一条")
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .onAppear {
                if viewModel.filterFocusConditionID == conditionID {
                    valueFocused = true
                }
            }
            .onChange(of: viewModel.filterFocusToken) { _, _ in
                if viewModel.filterFocusConditionID == conditionID {
                    valueFocused = true
                }
            }
        }
    }

    // MARK: 值控件（按操作符与列类型选择）

    @ViewBuilder
    private func valueEditor(_ condition: FilterCondition) -> some View {
        let column = viewModel.columnInfo(named: condition.column)
        if !condition.op.requiresValue {
            TextField("", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
                .help("该操作符不需要值")
        } else if let options = dropdownOptions(for: column),
                  condition.op == .equal || condition.op == .notEqual {
            Picker("值", selection: valueBinding) {
                Text("选择值").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        } else if condition.op.requiresSecondValue {
            HStack(spacing: 4) {
                TextField("最小值", text: valueBinding)
                    .textFieldStyle(.roundedBorder)
                    .focused($valueFocused)
                Text("和").foregroundStyle(.secondary)
                TextField("最大值", text: secondValueBinding)
                    .textFieldStyle(.roundedBorder)
            }
        } else if condition.op.isListOperator {
            TextField("值1, 值2, …", text: valueBinding)
                .textFieldStyle(.roundedBorder)
                .focused($valueFocused)
        } else {
            TextField("值", text: valueBinding)
                .textFieldStyle(.roundedBorder)
                .focused($valueFocused)
        }
    }

    /// ENUM / SET / TINYINT(1) 的值域。
    private func dropdownOptions(for column: ColumnInfo?) -> [String]? {
        guard let column else { return nil }
        if let values = column.enumValues, !values.isEmpty { return values }
        if column.isBooleanTinyInt { return ["0", "1"] }
        return nil
    }

    private var rowBackground: Color {
        if viewModel.isFilterConditionErrored(conditionID) { return Color.red.opacity(0.12) }
        if condition?.isIncomplete == true { return Color.yellow.opacity(0.20) }
        return Color.clear
    }

    // MARK: 绑定

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { condition?.isEnabled ?? true },
            set: { viewModel.setFilterConditionEnabled(id: conditionID, enabled: $0) }
        )
    }

    private var operatorBinding: Binding<FilterOperator> {
        Binding(
            get: { condition?.op ?? .equal },
            set: { viewModel.setFilterConditionOperator(id: conditionID, op: $0) }
        )
    }

    private var valueBinding: Binding<String> {
        Binding(
            get: { condition?.value ?? "" },
            set: { viewModel.setFilterConditionValue(id: conditionID, value: $0) }
        )
    }

    private var secondValueBinding: Binding<String> {
        Binding(
            get: { condition?.secondValue ?? "" },
            set: { viewModel.setFilterConditionSecondValue(id: conditionID, value: $0) }
        )
    }
}

// MARK: - 列下拉（可搜索）

/// 列下拉：点开后是一个带搜索框的列表（列很多时按 `specs/05-filtering.md` §1）。
private struct ColumnPickerButton: View {

    let columns: [ColumnInfo]
    let selected: String
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var query = ""

    private var filtered: [ColumnInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return columns }
        return columns.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        Button {
            query = ""
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(selected.isEmpty ? "选择列" : selected)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                TextField("搜索列…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { column in
                            Button {
                                onSelect(column.name)
                                isPresented = false
                            } label: {
                                HStack(spacing: 6) {
                                    if column.isPrimaryKey {
                                        Image(systemName: "key.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(column.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(column.columnTypeText ?? column.dataType ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                        if filtered.isEmpty {
                            Text("没有匹配的列")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                }
            }
            .frame(width: 240, height: 260)
        }
    }
}
