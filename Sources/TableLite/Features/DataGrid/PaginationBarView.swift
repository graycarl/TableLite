import SwiftUI

/// 分页栏（`specs/03-data-browsing.md` §2）。在状态栏之上、网格之下。
///
/// 显示「行 1–300 / 约 12,480 行 · 第 1 页 · 300 行/页」、翻页、页码跳转、精确统计。
/// 行数是估算值，前面标「约」（L10）；深分页给 L11 提示。
struct PaginationBarView: View {

    let viewModel: TableDataViewModel

    @State private var pageSizeText = ""
    @State private var jumpText = ""

    var body: some View {
        VStack(spacing: 0) {
            if let hint = viewModel.noPrimaryKeyHint {
                banner(text: hint, systemImage: "key.slash", tint: .orange)
            }
            if let hint = viewModel.deepOffsetHint {
                banner(text: hint, systemImage: "exclamationmark.triangle", tint: .yellow)
            }
            Divider()
            controls
        }
        .onAppear { syncTexts() }
        .onChange(of: viewModel.pageSize) { _, _ in pageSizeText = String(viewModel.pageSize) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(rangeText)
                .font(.callout)
                .monospacedDigit()

            Text("第 \(viewModel.pageIndex + 1) 页")
                .font(.callout)
                .foregroundStyle(.secondary)

            pageSizeControl

            Spacer(minLength: 12)

            Button {
                viewModel.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(viewModel.pageIndex <= 0 || viewModel.loadState.isLoading)
            .help("上一页")

            Button {
                viewModel.goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.hasNextPage || viewModel.loadState.isLoading)
            .help("下一页")

            Text("跳到")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("", text: $jumpText)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyJump() }

            Button("精确统计") {
                viewModel.runExactCount()
            }
            .disabled(viewModel.isCountingExact || !viewModel.isMetadataLoaded)
            .help("执行一次 COUNT(*)，可能很慢")

            if viewModel.isCountingExact {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
    }

    private var pageSizeControl: some View {
        HStack(spacing: 3) {
            TextField("", text: $pageSizeText)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyCustomPageSize() }
            Text("行/页")
                .font(.callout)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(PageSize.presets, id: \.self) { size in
                    Button("\(size) 行/页") { viewModel.setPageSize(size) }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("每页行数（上限 \(PageSize.maximum)）")
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

    private var rangeText: String {
        let page = viewModel.pageState
        let visible = viewModel.rows.count
        let first = visible == 0 ? 0 : page.offset + 1
        let last = page.offset + visible
        let total = viewModel.rowCountEstimate?.displayText ?? "行数未知"
        return "行 \(first)–\(last) / \(total)"
    }

    private func syncTexts() {
        pageSizeText = String(viewModel.pageSize)
    }

    private func applyCustomPageSize() {
        guard let value = Int(pageSizeText.trimmingCharacters(in: .whitespaces)) else {
            pageSizeText = String(viewModel.pageSize)
            return
        }
        let clamped = min(max(value, 1), PageSize.maximum)
        viewModel.setPageSize(clamped)
        pageSizeText = String(viewModel.pageSize)
    }

    private func applyJump() {
        defer { jumpText = "" }
        guard let value = Int(jumpText.trimmingCharacters(in: .whitespaces)) else { return }
        viewModel.goToPage(max(0, value - 1))
    }
}
