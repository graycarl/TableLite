import AppKit

// MARK: - SQL 文本视图
//
// `NSTextView` 子类：Tab 插入固定个数空格、简单自动缩进（继承上一行前导空白）、
// 本地 `⌘↩` / `⇧⌘↩` / `⌘.` 快捷键。见 docs/tech-designs/10-query-editor.md §2。
//
// 智能替换的关闭在 `SQLEditorView.makeNSView` 里统一设置（硬约束）。

@MainActor
final class SQLEditorTextView: NSTextView {

    /// `preferences.editorIndentWidth`
    var indentWidth: Int = 4

    var onExecute: (() -> Void)?
    var onExecuteAll: (() -> Void)?
    var onStop: (() -> Void)?

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 36, 76: // Return / 小键盘 Enter
                if event.modifierFlags.contains(.shift) {
                    onExecuteAll?()
                } else {
                    onExecute?()
                }
                return
            case 47: // .
                onStop?()
                return
            default:
                break
            }
        }

        if event.keyCode == 48, !event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                shiftSelectionOutdent()
            } else {
                insertIndent()
            }
            return
        }

        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let selected = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: min(selected.location, ns.length), length: 0))
        let headLength = max(0, min(selected.location, NSMaxRange(lineRange)) - lineRange.location)
        let head = ns.substring(with: NSRange(location: lineRange.location, length: headLength))
        let indent = leadingWhitespace(of: head)

        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(indent, replacementRange: selectedRange())
        }
    }

    // MARK: 缩进

    private func insertIndent() {
        let spaces = String(repeating: " ", count: max(1, indentWidth))
        let range = selectedRange()
        if range.length == 0 {
            insertText(spaces, replacementRange: range)
        } else {
            let ns = string as NSString
            let block = ns.lineRange(for: range)
            let source = ns.substring(with: block)
            let indented = source
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? $0 : spaces + $0 }
                .joined(separator: "\n")
            insertText(indented, replacementRange: block)
        }
    }

    private func shiftSelectionOutdent() {
        let ns = string as NSString
        let range = selectedRange()
        let block = ns.lineRange(for: range)
        let source = ns.substring(with: block)
        let outdented = source
            .components(separatedBy: "\n")
            .map { line -> String in
                var text = Substring(line)
                var removed = 0
                while removed < max(1, indentWidth), text.first == " " {
                    text = text.dropFirst()
                    removed += 1
                }
                return String(text)
            }
            .joined(separator: "\n")
        if outdented != source {
            insertText(outdented, replacementRange: block)
        }
    }

    private func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }
}
