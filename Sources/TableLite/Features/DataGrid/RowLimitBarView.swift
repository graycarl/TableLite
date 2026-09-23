import SwiftUI

/// 显示条数栏（`specs/03-data-browsing.md` §2）。在网格之下、窗口状态栏之上。
///
/// 只有一件事：切换「最多显示多少行」，外加一个「精确统计」把行数估算换成精确总行数。
/// 没有页码 / 翻页 / 跳页（取消分页，见 `docs/tech-designs/07-data-grid.md` §7）。
struct RowLimitBarView: View {

    let viewModel: TableDataViewModel

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
            Text("显示 \(viewModel.rows.count) 行 / \(viewModel.rowCountEstimate?.displayText ?? "行数未知")")
                .font(.callout)
                .monospacedDigit()

            limitControl

            Spacer(minLength: 12)

            Button("精确统计") {
                viewModel.runExactCount()
            }
            .disabled(viewModel.isCountingExact || !viewModel.isMetadataLoaded)
            .help("执行一次 COUNT(*)，可能很慢；完成后把「约 N 行」换成精确总行数")

            if viewModel.isCountingExact {
                ProgressView()
                    .controlSize(.small)
            }
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
                Text("最多 \(viewModel.rowLimit) 行")
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
