import AppKit
import SwiftUI

// MARK: - 预览将要执行的 SQL
//
// `⌘⇧P` 打开。逐条列出将执行的 SQL（与提交完全一致），支持复制全部、
// 在新查询标签中打开、放弃、提交。见 specs/04-data-editing.md §9、docs/tech-designs/08-pending-changes.md §4。

struct PendingPreviewSheet: View {
    let statements: [PendingSQLStatement]
    var onOpenInQuery: ([PendingSQLStatement]) -> Void
    var onDiscard: () -> Void
    var onSubmit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copiedToast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("将要执行的 SQL（\(statements.count) 条）")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(statements) { statement in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(statement.id)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(SQLSyntaxHighlighter.attributed(statement.text, fontSize: 12))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 260)
            Divider()
            HStack(spacing: 10) {
                Button("复制全部") { copyAll() }
                Button("在新查询标签中打开") { onOpenInQuery(statements) }
                if let copiedToast {
                    Text(copiedToast)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("提交") {
                    onSubmit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 380)
    }

    private func copyAll() {
        let text = statements.map(\.text).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedToast = "已复制 \(statements.count) 条语句"
    }
}

// MARK: - SQL 语法高亮

/// 用 `SQLLexer` 给 SQL 上色（预览面板用；编辑器另有实现）。
enum SQLSyntaxHighlighter {

    static func attributed(_ sql: String, fontSize: Double) -> AttributedString {
        let base = NSMutableAttributedString(
            string: sql,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let nsString = sql as NSString
        for token in SQLLexer.tokenize(sql) {
            guard token.range.location != NSNotFound,
                  NSMaxRange(token.range) <= nsString.length else { continue }
            base.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        return AttributedString(base)
    }

    private static func color(for kind: SQLTokenKind) -> NSColor {
        switch kind {
        case .keyword: return NSColor.systemBlue
        case .function: return NSColor.systemPurple
        case .type: return NSColor.systemTeal
        case .string: return NSColor.systemRed
        case .backtick: return NSColor.systemBrown
        case .number: return NSColor.systemOrange
        case .comment: return NSColor.systemGray
        case .variable, .parameter: return NSColor.systemIndigo
        case .operatorSymbol, .punctuation: return NSColor.secondaryLabelColor
        case .identifier: return NSColor.labelColor
        }
    }
}
