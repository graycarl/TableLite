import SwiftUI
import AppKit

/// 结果区：结果标签栏 + 当前结果内容（`docs/tech-designs/10-query-editor.md` §6）。
struct QueryResultAreaView: View {

    @Bindable var viewModel: QueryEditorViewModel
    let displayContext: CellDisplayContext
    let fontSize: Double
    let alternateRowColors: Bool
    var onQuickLook: (QuickLookContent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: 标签栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(visibleTabs) { result in
                        ResultTabButton(
                            result: result,
                            isActive: result.id == viewModel.selectedResult?.id,
                            onSelect: { viewModel.selectResult(result.id) },
                            onClose: { viewModel.closeResult(result.id) },
                            onCloseOther: { viewModel.closeOtherResults(keeping: result.id) },
                            onCopyStatement: { viewModel.copyStatement(result) },
                            onCopyResult: { viewModel.copyResult(result) }
                        )
                    }
                    if !overflowTabs.isEmpty {
                        overflowMenu
                    }
                }
            }
            Spacer(minLength: 0)
            summary
        }
        .frame(height: 32)
        .background(.bar)
    }

    /// 超过 24 个时折叠：前 23 个直接显示，其余收进 `…` 下拉（`specs/06-query-editor.md` §4）。
    private var visibleTabs: [QueryResultTab] {
        viewModel.results.count > 24 ? Array(viewModel.results.prefix(23)) : viewModel.results
    }

    private var overflowTabs: [QueryResultTab] {
        viewModel.results.count > 24 ? Array(viewModel.results.dropFirst(23)) : []
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(overflowTabs) { result in
                Button(result.title) { viewModel.selectResult(result.id) }
            }
        } label: {
            Text("…")
                .font(.callout)
                .padding(.horizontal, 10)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 40)
    }

    private var summary: some View {
        Text(summaryText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 12)
    }

    private var summaryText: String {
        var parts: [String] = []
        if viewModel.resultSetCount > 0 {
            parts.append("共 \(viewModel.resultSetCount) 条")
        }
        if viewModel.executedStatementCount > 0 {
            parts.append("已执行 \(viewModel.executedStatementCount) 条语句")
        }
        if viewModel.elapsedMilliseconds > 0 {
            parts.append("耗时 \(viewModel.elapsedMilliseconds) ms")
        }
        if viewModel.totalReturnedRows > 0 {
            parts.append("返回 \(viewModel.totalReturnedRows) 行")
        }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let result = viewModel.selectedResult {
            QueryResultDetailView(
                result: result,
                displayContext: displayContext,
                fontSize: fontSize,
                alternateRowColors: alternateRowColors,
                onQuickLook: onQuickLook
            )
        } else if viewModel.isRunning {
            ResultStatusPanel(
                symbol: "hourglass",
                tint: .secondary,
                title: "正在执行…",
                detail: progressText
            )
        } else {
            ResultStatusPanel(symbol: "play.circle", tint: .secondary, title: "按 ⌘↩ 执行语句")
        }
    }

    private var progressText: String {
        "已接收 \(viewModel.receivedRowCount) 行（\(viewModel.elapsedMilliseconds / 1000).\(viewModel.elapsedMilliseconds % 1000 / 100) 秒）"
    }
}

// MARK: - 单个结果标签

private struct ResultTabButton: View {

    let result: QueryResultTab
    let isActive: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onCloseOther: () -> Void
    var onCopyStatement: () -> Void
    var onCopyResult: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                if result.isFailure {
                    Image(systemName: result.symbolName)
                        .font(.caption2)
                        .foregroundStyle(result.kind == .blocked ? .orange : .red)
                }
                Text(result.title)
                    .font(.callout)
                    .foregroundStyle(result.isFailure && !isActive
                        ? (result.kind == .blocked ? Color.orange : Color.red)
                        : Color.primary)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(isActive ? Color(nsColor: .windowBackgroundColor) : Color.clear)
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("关闭") { onClose() }
            Button("关闭其他") { onCloseOther() }
                .disabled(false)
            Divider()
            Button("复制这条语句") { onCopyStatement() }
            Button("复制结果") { onCopyResult() }
                .disabled(result.rows.isEmpty)
        }
    }
}
