import SwiftUI

/// 网格底部条（`specs/03-data-browsing.md` §2、`specs/02-workspace.md` §7）。在网格之下、窗口状态栏之上。
///
/// 表数据标签里网格下方唯一的「概况 + 操作」条：
/// - 左侧：行数（`300 / 约 12,480 行`）、显示条数下拉、`统计`；慢加载时行数后跟耗时与「取消」；
/// - 右侧：`筛选` / `列` / `导出` 三个操作入口（原先在窗口状态栏，现已并进来）。
///
/// 没有页码 / 翻页 / 跳页（取消分页，见 `docs/tech-designs/07-data-grid.md` §7）。
struct GridStatusBarView: View {

    let viewModel: TableDataViewModel
    /// 导出当前过滤条件下的全部数据（`specs/08-import-export.md`）。
    var onExport: () -> Void

    @State private var isCustomLimitPresented = false
    @State private var customLimitText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let hint = viewModel.noPrimaryKeyHint {
                banner(text: hint, systemImage: "key.slash", tint: .orange)
            }
            Divider()
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            // 行数 + 慢加载耗时；阈值判断统一在 `WorkspaceStatusText.tableDataSummary`。
            Text(WorkspaceStatusText.tableDataSummary(
                base: viewModel.rowCountBarText,
                elapsedMilliseconds: viewModel.elapsedMilliseconds
            ))
            .font(.callout)
            .monospacedDigit()

            // 超过 10 秒的加载附「取消」（`specs/12-feedback.md` §6）。
            if viewModel.loadState.isLoading,
               WorkspaceStatusText.showsCancelButton(elapsedMilliseconds: viewModel.elapsedMilliseconds) {
                Button("取消") { viewModel.cancelInFlight() }
                    .controlSize(.small)
                    .help("取消正在进行的查询（⌘.）")
            }

            limitControl

            Button("统计") {
                viewModel.runExactCount()
            }
            .disabled(viewModel.isCountingExact || !viewModel.isMetadataLoaded)
            .help("执行一次 COUNT(*)，可能很慢；完成后把「约 N 行」换成精确总行数")

            if viewModel.isCountingExact {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 12)

            Button("筛选") { viewModel.toggleFilterVisible() }
                .controlSize(.small)
                .help("打开或关闭行过滤器（⌘F）")
            Button("列") { viewModel.presentColumnFilter() }
                .controlSize(.small)
                .help("选择要显示的列（⌥⌘F）")
            Button("导出", action: onExport)
                .controlSize(.small)
                .help("导出当前过滤条件下的全部数据（⇧⌘E）")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }

    /// 单个下拉按钮：标签直接显示当前上限，档位在菜单里，手填走「自定义…」。
    private var limitControl: some View {
        Menu {
            ForEach(RowLimit.presets, id: \.self) { size in
                Button("\(size) 行") { viewModel.setRowLimit(size) }
            }
            Divider()
            Button("自定义…") {
                customLimitText = String(viewModel.rowLimit)
                isCustomLimitPresented = true
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(viewModel.rowLimit)")
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("最多显示多少行（上限 \(RowLimit.maximum)）")
        .alert("最多显示多少行", isPresented: $isCustomLimitPresented) {
            TextField("行数", text: $customLimitText)
            Button("确定") { applyCustomLimit() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入 1 – \(RowLimit.maximum) 之间的整数")
        }
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
            Spacer()
        }
        .font(.callout)
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
