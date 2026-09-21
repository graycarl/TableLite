import SwiftUI

// MARK: - 列过滤浮层
//
// `⌥⌘F` / 状态栏「列」打开：搜索、全选 / 全不选、每列勾选。
// 至少保留一列可见，否则「应用」禁用并提示。
// 列显隐只影响数据网格，不影响右侧字段栏（字段栏读 `allColumns`）。
//
// 见 docs/tech-designs/09-filtering.md §2、specs/05-filtering.md §2。

struct ColumnFilterPopover: View {

    @ObservedObject var model: TableDataViewModel
    @Binding var isPresented: Bool
    var onToast: (String) -> Void

    @State private var query = ""
    /// 草稿：勾选过程中先改这里，点「应用」才写回 `model.hiddenColumns`。
    @State private var hidden: Set<String>

    init(model: TableDataViewModel,
         isPresented: Binding<Bool>,
         onToast: @escaping (String) -> Void) {
        self.model = model
        self._isPresented = isPresented
        self.onToast = onToast
        self._hidden = State(initialValue: model.hiddenColumns)
    }

    private var columns: [TableColumn] { model.allColumns }
    private var filteredColumns: [TableColumn] { FilterPanelLogic.searchColumns(columns, query: query) }
    private var canApply: Bool { FilterPanelLogic.canApplyColumnFilter(hidden: hidden, columns: columns) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("显示的列").font(.headline)
                Spacer()
            }
            .padding(12)

            Divider()

            HStack(spacing: 6) {
                TextField("搜索列…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("全选") { hidden = [] }
                Button("全不选") { hidden = allSelectableNames }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredColumns.isEmpty {
                        Text("没有匹配的列")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else {
                        ForEach(filteredColumns, id: \.name) { column in
                            Toggle(isOn: visibleBinding(for: column)) {
                                HStack(spacing: 6) {
                                    Text(column.name)
                                        .font(.system(.callout, design: .monospaced))
                                    if column.isPrimaryKey {
                                        Text("(主键)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("(\(column.rawTypeText.uppercased()))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            if !canApply {
                Text("至少保留一列可见")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button("应用") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
            .padding(12)
        }
        .frame(width: 340)
    }

    private var allSelectableNames: Set<String> {
        Set(FilterPanelLogic.selectableColumns(columns).map(\.name))
    }

    private func visibleBinding(for column: TableColumn) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(column.name) },
            set: { visible in
                if visible {
                    hidden.remove(column.name)
                } else {
                    hidden.insert(column.name)
                }
            }
        )
    }

    private func apply() {
        guard canApply else {
            onToast("至少保留一列可见")
            return
        }
        model.setHiddenColumns(FilterPanelLogic.sanitizedHiddenColumns(hidden, columns: columns))
        isPresented = false
    }
}
