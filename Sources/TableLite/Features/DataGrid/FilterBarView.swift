import SwiftUI

/// 过滤栏占位（`specs/03-data-browsing.md` §1 的过滤条件区域）。
///
/// P6 / W3-T10 会用真正的 `FilterPanelView` 替换这里。当前只在
/// `tab.filter?.isVisible` 为真时占一行，提示功能待实现。
/// ViewModel 已经暴露 `setFilter(_:)` / `setFilterVisible(_:)` 接入口。
struct FilterBarView: View {

    let viewModel: TableDataViewModel

    var body: some View {
        if viewModel.isFilterVisible {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    Text("过滤器（待 W6 实现）")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        viewModel.setFilterVisible(false)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("关闭过滤栏")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(.bar)
                Divider()
            }
        }
    }
}
