import SwiftUI
import AppKit

/// 预览 sheet：逐条列出将执行的 SQL（`specs/04-data-editing.md` §9）。
///
/// 面板里的语句来自 `viewModel.makeStatements()`，与实际提交是**同一条生成路径**（S29）。
struct PreviewSQLSheet: View {

    let viewModel: TableDataViewModel
    var onClose: () -> Void

    private var statements: [String] { viewModel.previewStatements }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("将要执行的 SQL（\(statements.count) 条）")
                    .font(.headline)
                Spacer()
            }
            .padding(10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(statements.enumerated()), id: \.offset) { index, sql in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            // L30：预览 SQL 加语法高亮（复用 SQLLexer）。
                            SQLHighlightedText(sql: sql)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 6)
            }

            Divider()

            HStack(spacing: 8) {
                Button("复制全部") { copyAll() }
                    .disabled(statements.isEmpty)
                Button("在新查询标签中打开") {
                    viewModel.openPreviewInQueryTab()
                    onClose()
                }
                .disabled(statements.isEmpty)
                Spacer()
                Button("关闭") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("提交") {
                    onClose()
                    viewModel.requestSubmit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(statements.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 620, minHeight: 380)
    }

    private func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(statements.joined(separator: "\n"), forType: .string)
    }
}

/// 提交失败面板（`specs/04-data-editing.md` §10、`specs/12-feedback.md` §5）。
struct CommitFailureSheet: View {

    let failure: CommitFailure
    var onDiscardAll: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(failure.title)
                    .font(.headline)
            }

            Text(failure.isCancelled ? "提交已取消" : "第 \(failure.index) 条语句执行失败")
                .foregroundStyle(.secondary)

            if let codeLine = failure.codeLine {
                Text(codeLine)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure.message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(failure.statement)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 120)

            if let explanation = failure.explanation {
                Text(explanation)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(failure.impactText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("放弃全部修改", action: onDiscardAll)
                Spacer()
                Button("关闭并修正", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
    }
}
