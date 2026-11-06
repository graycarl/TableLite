import SwiftUI

/// 网格底部条（`specs/03-data-browsing.md` §2）。在网格之下，是表数据标签里唯一的「概况 + 操作」条，
/// 也是不可编辑原因横幅的挂载点。
///
/// 左侧是紧凑行数 + 行数菜单（显示条数 / 精确统计 / 自定义）、慢加载耗时与取消、大字段大小 chip；
/// 右侧是 `筛选` / `列` / `导出`。没有页码 / 翻页 / 跳页（取消分页，见
/// `docs/tech-designs/07-data-grid.md` §7）。
struct GridStatusBarView: View {

    let viewModel: TableDataViewModel
    /// 导出当前过滤条件下的全部数据（`specs/08-import-export.md`）。
    var onExport: () -> Void

    @State private var isCustomLimitPresented = false
    @State private var customLimitText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let hint = viewModel.uneditableStatusText {
                banner(text: hint, systemImage: uneditableIcon, tint: .orange)
            }
            Divider()
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            countMenu

            if viewModel.isCountingExact {
                ProgressView()
                    .controlSize(.small)
                Button("取消") { viewModel.cancelInFlight() }
                    .buttonStyle(.subtle)
                    .controlSize(.small)
                    .help("取消精确统计（⌘.）")
                    .accessibilityIdentifier("grid.statusbar.cancel-count")
            }

            // 超过 10 秒的加载附「取消」（`specs/12-feedback.md` §6）。
            if viewModel.loadState.isLoading,
               WorkspaceStatusText.showsCancelButton(elapsedMilliseconds: viewModel.elapsedMilliseconds) {
                Button("取消") { viewModel.cancelInFlight() }
                    .buttonStyle(.subtle)
                    .controlSize(.small)
                    .help("取消正在进行的查询（⌘.）")
                    .accessibilityIdentifier("grid.statusbar.cancel")
            }

            if let summary = viewModel.largeFieldSizeSummary {
                largeFieldChip(summary)
            }

            Spacer(minLength: 8)

            Button {
                viewModel.toggleFilterVisible()
            } label: {
                Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.subtle)
            .controlSize(.small)
            .help("打开或关闭行过滤器（⌘F）")
            .accessibilityIdentifier("grid.statusbar.filter")
            .popover(isPresented: filterBinding, arrowEdge: .bottom) {
                FilterBarView(viewModel: viewModel)
            }

            Button {
                viewModel.presentColumnFilter()
            } label: {
                Label("列", systemImage: "rectangle.3.group")
            }
            .buttonStyle(.subtle)
            .controlSize(.small)
            .help("选择要显示的列（⌥⌘F）")
            .accessibilityIdentifier("grid.statusbar.columns")

            Button(action: onExport) {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.subtle)
            .controlSize(.small)
            .help("导出当前过滤条件下的全部数据（⇧⌘E）")
            .accessibilityIdentifier("grid.statusbar.export")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }

    private var filterBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isFilterVisible },
            set: { viewModel.setFilterVisible($0) }
        )
    }

    /// 行数 + 显示条数 + 精确统计合并成一个菜单，避免三个控件抢底部条宽度。
    private var countMenu: some View {
        Menu {
            Button {
                viewModel.runExactCount()
            } label: {
                Label(
                    viewModel.isCountingExact ? "正在精确统计…" : "精确统计行数",
                    systemImage: "number"
                )
            }
            .disabled(viewModel.isCountingExact || !viewModel.isMetadataLoaded)
            .accessibilityIdentifier("grid.statusbar.stats")

            Divider()

            ForEach(RowLimit.presets, id: \.self) { size in
                Button {
                    viewModel.setRowLimit(size)
                } label: {
                    if size == viewModel.rowLimit {
                        Label("\(size) 行", systemImage: "checkmark")
                    } else {
                        Text("\(size) 行")
                    }
                }
            }

            Divider()

            Button("自定义…") {
                customLimitText = String(viewModel.rowLimit)
                isCustomLimitPresented = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(WorkspaceStatusText.tableDataSummary(
                    base: viewModel.compactRowCountText,
                    elapsedMilliseconds: viewModel.elapsedMilliseconds
                ))
                .font(AppFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .layoutPriority(1)
        .help("行数 / 显示条数 / 精确统计")
        .accessibilityIdentifier("grid.statusbar.row-limit")
        .alert("最多显示多少行", isPresented: $isCustomLimitPresented) {
            TextField("行数", text: $customLimitText)
            Button("确定") { applyCustomLimit() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入 1 – \(RowLimit.maximum) 之间的整数")
        }
    }

    private func largeFieldChip(_ summary: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(summary)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .help("这些列的大字段只加载了截断值；选中行或点开单元格时会取完整内容")
    }

    /// 不可编辑原因前的图标：无主键 / 视图 / 只读连接各一个（`specs/03-data-browsing.md` §11）。
    private var uneditableIcon: String {
        switch viewModel.editability.reason {
        case .noPrimaryKey: return "key.slash"
        case .view: return "eye"
        case .readOnlyConnection, nil: return "lock"
        }
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
            Spacer()
        }
        .font(AppFont.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10))
    }

    private func applyCustomLimit() {
        guard let value = Int(customLimitText.trimmingCharacters(in: .whitespaces)) else { return }
        viewModel.setRowLimit(min(max(value, 1), RowLimit.maximum))
    }
}
