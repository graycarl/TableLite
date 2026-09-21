import SwiftUI

// MARK: - 右侧字段栏
//
// 网格的「焦点单元格 / 选区」的唯一投影与唯一编辑入口。
// 见 docs/tech-designs/14-row-inspector.md、specs/03-data-browsing.md §7、specs/04-data-editing.md §3。
//
// 本视图不持有暂存数据：改动经 `TableDataViewModel` 落进暂存区，再从暂存区反查渲染。

struct RowInspectorView: View {

    @ObservedObject var model: TableDataViewModel
    @ObservedObject var preferences: PreferencesStore

    /// 网格双击某个单元格时请求聚焦对应字段；消费后置回 nil。
    @Binding var focusRequest: String?
    var onQuickLook: (RowIdentity, String) -> Void

    @State private var search = ""

    private var columns: [TableColumn] { model.allColumns }

    private var filteredColumns: [TableColumn] {
        let keyword = search.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return columns }
        return columns.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索字段", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Spacer()
                Text(search.isEmpty ? "共 \(columns.count) 个字段" : "显示 \(filteredColumns.count) / \(columns.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let selectedCount = multiSelectionWarning {
            placeholder(selectedCount)
        } else if let row = model.focusedRow, let rowData = model.focusedRowData {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    banner(for: row)
                    ForEach(Array(filteredColumns.enumerated()), id: \.element.name) { _, column in
                        RowInspectorFieldRow(
                            model: model,
                            preferences: preferences,
                            row: rowData,
                            column: column,
                            value: value(for: column, in: rowData),
                            isEditable: isEditable(row: row),
                            isDeleted: isDeleted(row: row),
                            focusRequest: $focusRequest,
                            onQuickLook: onQuickLook
                        )
                        Divider()
                    }
                }
                // 切换行时重建字段列表，避免草稿串行
                .id(rowData.identity)
            }
            if let message = model.fullValueError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        } else {
            VStack {
                Spacer()
                Text("选中一行以查看和编辑它的字段")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func placeholder(_ count: Int) -> some View {
        VStack {
            Spacer()
            Text("已选中 \(count) 行 · 请只选一行")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func banner(for row: RowIdentity) -> some View {
        if isDeleted(row: row) {
            HStack {
                Text("这一行已标记删除")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                Spacer()
                Button("撤销删除") { model.undoRow(row) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
        } else if row.isInserted {
            Text("新增行")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08))
        } else if !model.editability.isEditable {
            Text(model.editability.message ?? "该表不可编辑")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
        }
    }

    // MARK: 状态

    private var multiSelectionWarning: Int? {
        guard model.focusedRow != nil else { return nil }
        let count = model.selectedRows.count
        return count > 1 ? count : nil
    }

    private func isDeleted(row: RowIdentity) -> Bool {
        model.pending.change(for: row)?.kind == .delete
    }

    private func isEditable(row: RowIdentity) -> Bool {
        model.editability.isEditable && !isDeleted(row: row)
    }

    private func value(for column: TableColumn, in rowData: TableDataRow) -> CellValue {
        if let full = model.fullValue(row: rowData.identity, column: column.name) {
            return full
        }
        guard let index = columns.firstIndex(where: { $0.name == column.name }),
              index < rowData.values.count else {
            return .null
        }
        return rowData.values[index]
    }
}
