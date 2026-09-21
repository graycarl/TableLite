import SwiftUI

// MARK: - 过滤器条件行
//
// 「启用勾选 + 列下拉（可搜索）+ 操作符下拉 + 值输入 + / −」。
// 见 specs/05-filtering.md §1。状态由父视图通过 `Binding<FilterCondition>` 传入，
// 真源始终是 `TableDataViewModel.filter`。

struct FilterConditionRow: View {

    @Binding var condition: FilterCondition
    let columns: [TableColumn]
    /// 应用时报错（例如引用了不存在的列）时高亮该行。
    let isHighlighted: Bool
    /// 父视图统一持有的焦点状态（「按此列筛选」后聚焦值输入）。
    @FocusState.Binding var focusedConditionID: UUID?
    var onAdd: () -> Void
    var onRemove: () -> Void

    private var selectedColumn: TableColumn? {
        columns.first { $0.name == condition.column }
    }

    private var valueOptions: [String]? {
        guard FilterPanelLogic.usesValuePicker(op: condition.op, column: selectedColumn) else { return nil }
        return selectedColumn.flatMap { FilterPanelLogic.valueOptions(for: $0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $condition.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("启用这条条件")

            FilterColumnPicker(columns: columns, selection: $condition.column)

            Picker("", selection: $condition.op) {
                ForEach(FilterOperator.allCases) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .help("比较方式")

            valueInputs

            Spacer(minLength: 0)

            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("在下方添加一条条件（⌘I）")

            Button(action: onRemove) {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .help("删除这条条件")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHighlighted ? Color.red.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isHighlighted ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var valueInputs: some View {
        switch FilterPanelLogic.valueField(for: condition.op) {
        case .none:
            EmptyView()
        case .single:
            valueInput(text: $condition.value, placeholder: "值", focusable: true)
        case .double:
            valueInput(text: $condition.value, placeholder: "下限", focusable: true)
            Text("到")
                .font(.callout)
                .foregroundStyle(.secondary)
            valueInput(text: $condition.secondValue, placeholder: "上限", focusable: false)
        }
    }

    @ViewBuilder
    private func valueInput(text: Binding<String>, placeholder: String, focusable: Bool) -> some View {
        if let options = valueOptions {
            Picker("", selection: text) {
                Text(placeholder).tag("")
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .frame(minWidth: 110, maxWidth: 200)
            .help(placeholder)
        } else if focusable {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 110, maxWidth: 220)
                .focused($focusedConditionID, equals: condition.id)
        } else {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 110, maxWidth: 220)
        }
    }
}

// MARK: - 可搜索的列下拉

/// 列下拉：列很多时带搜索框（specs/05 §1）。
struct FilterColumnPicker: View {

    let columns: [TableColumn]
    @Binding var selection: String

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(selection.isEmpty ? "选择列" : selection)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(selection.isEmpty ? Color.secondary : Color.primary)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 96, maxWidth: 180)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("搜索列…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let filtered = FilterPanelLogic.searchColumns(columns, query: query)
                        if filtered.isEmpty {
                            Text("没有匹配的列")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(8)
                        } else {
                            ForEach(filtered, id: \.name) { column in
                                Button {
                                    selection = column.name
                                    isPresented = false
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(column.name)
                                            .font(.system(.callout, design: .monospaced))
                                        if column.isPrimaryKey {
                                            Text("主键")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        if selection == column.name {
                                            Image(systemName: "checkmark")
                                                .font(.caption)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            .frame(width: 240)
        }
        .onChange(of: isPresented) { _, presented in
            if presented { query = "" }
        }
    }
}
