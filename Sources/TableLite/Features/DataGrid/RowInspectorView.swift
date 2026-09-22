import SwiftUI

/// 右侧字段栏（只读版）。见 `specs/03-data-browsing.md` §7、`docs/tech-designs/14-row-inspector.md`。
///
/// 本阶段（P4）只做只读展示：字段按表定义顺序排列、显示类型、值只读。
/// T9 会把 `InspectorFieldRow` 的只读 `Text` 换成按列类型选择的编辑器；
/// 值模型 `GridCell`（原始值 / 截断值 / 完整值 / 编辑中值）已经就位。
struct RowInspectorView: View {

    let viewModel: TableDataViewModel

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索字段", text: $searchText)
                    .textFieldStyle(.plain)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let reason = readOnlyReason {
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                    Text(reason)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var countText: String {
        if searchText.isEmpty {
            return "\(viewModel.columns.count) 个字段"
        }
        return "显示 \(filteredColumns.count) / \(viewModel.columns.count)"
    }

    private var readOnlyReason: String? {
        guard viewModel.isMetadataLoaded, !viewModel.isEditable else { return nil }
        return viewModel.editability.reason?.message
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.selectedRowIDs.count > 1 {
            message("已选中 \(viewModel.selectedRowIDs.count) 行 · 请只选一行")
        } else if let row = viewModel.inspectorRow {
            fieldList(for: row)
        } else {
            message("选中一行以查看和编辑它的字段")
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fieldList(for row: GridRow) -> some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingFullRow {
                statusBar(text: "正在加载完整内容…", systemImage: "arrow.down.circle")
            } else if let error = viewModel.fullRowError {
                statusBar(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
            } else if viewModel.manualFullLoadRequired {
                manualLoadBar
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredColumns) { column in
                        InspectorFieldRow(
                            column: column,
                            cell: row.cells[column.name],
                            context: viewModel.cellDisplayContext,
                            isLoading: viewModel.isLoadingFullRow
                        )
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBar(text: String, systemImage: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.08))
    }

    private var manualLoadBar: some View {
        HStack(spacing: 6) {
            Button("加载完整内容…") {
                viewModel.requestFullRowLoad(force: true)
            }
            .controlSize(.small)
            Text("该行大字段合计超过 8 MB")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.08))
    }

    private var filteredColumns: [ColumnInfo] {
        guard !searchText.isEmpty else { return viewModel.columns }
        let needle = searchText.lowercased()
        return viewModel.columns.filter { $0.name.lowercased().contains(needle) }
    }
}

// MARK: - 字段行

/// 一个字段行：列名（主键加粗 + 🔑）、类型（灰小字）、只读值、`∅` 按钮。
///
/// T9 接缝：把 `valueText` 换成编辑器，把 `∅` 从禁用改为可点。
struct InspectorFieldRow: View {

    let column: ColumnInfo
    let cell: GridCell?
    let context: CellDisplayContext
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if column.isPrimaryKey {
                    Text("🔑")
                }
                Text(column.name)
                    .fontWeight(column.isPrimaryKey ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(column.typeDisplayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                valueView
                Button {
                    // T9：在 NULL 与上一个非 NULL 值之间切换。
                } label: {
                    Text("∅")
                        .frame(width: 20)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .help("设为 NULL（编辑功能待下一任务实现）")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var valueView: some View {
        Text(displayText)
            .font(valueFont)
            .foregroundStyle(isNullDisplay ? .secondary : .primary)
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor))
            )
            .help(tooltip ?? "")
    }

    private var display: CellDisplay {
        guard let cell else {
            return CellDisplay(text: "—")
        }
        return CellDisplayFormatter.display(
            value: cell.displayValue,
            isTruncated: cell.isTruncated && cell.fullValue == nil,
            totalByteCount: cell.totalByteCount,
            column: column,
            context: context
        )
    }

    private var displayText: String {
        display.text
    }

    private var valueFont: Font {
        isNullDisplay ? .system(size: 12).italic() : .system(size: 12)
    }

    private var isNullDisplay: Bool {
        display.isNull
    }

    private var tooltip: String? {
        if let tooltip = display.tooltip { return tooltip }
        return column.gridTypeTooltip
    }

    private var alignment: Alignment {
        display.alignment == .trailing ? .trailing : .leading
    }
}
