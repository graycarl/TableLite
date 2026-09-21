import AppKit

// MARK: - SQL 文本视图
//
// `NSTextView` 子类：Tab 插入固定个数空格、简单自动缩进（继承上一行前导空白）、
// 注释切换 / 缩进 / 反缩进，以及本地 `⌘↩` / `⇧⌘↩` / `⌘.` / `⌘/` / `⌘[` / `⌘]` 快捷键。
// 见 docs/tech-designs/10-query-editor.md §2、specs/02-workspace.md §8 §9。
//
// 所有文本变换统一走 `shouldChangeText(in:replacementString:)` + `textStorage.replaceCharacters`
// + `didChangeText()`，保证进入撤销栈。
//
// 智能替换的关闭在 `SQLEditorView.makeNSView` 里统一设置（硬约束）。

@MainActor
final class SQLEditorTextView: NSTextView {

    /// `preferences.editorIndentWidth`
    var indentWidth: Int = 4

    var onExecute: (() -> Void)?
    var onExecuteAll: (() -> Void)?
    var onStop: (() -> Void)?

    // MARK: 菜单 / 响应链入口
    //
    // 菜单项（`TableLiteApp`）通过 `SQLEditorCommands` 把动作发给第一响应者；
    // 只有编辑器是焦点时才命中这里（见 docs/tech-designs/06-ui-layer.md §5）。

    @objc func tableLiteToggleComment(_ sender: Any?) { toggleComment() }
    @objc func tableLiteIndentSelection(_ sender: Any?) { indentSelection() }
    @objc func tableLiteOutdentSelection(_ sender: Any?) { outdentSelection() }

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
            case 44: // /
                toggleComment()
                return
            default:
                break
            }
        }

        if event.keyCode == 48, !event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                outdentSelection()
            } else {
                indentSelection()
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
        let indent = Self.leadingWhitespace(of: head)

        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(indent, replacementRange: selectedRange())
        }
    }

    // MARK: 注释切换

    /// `⌘/`：逐行加 / 去 `-- ` 前缀。全部行已注释则取消注释，否则全部注释。
    ///
    /// 刻意简化：只认 `-- ` 行注释，不处理 `#`、`/* … */` 块注释（见 `13-open-questions.md` S36）。
    func toggleComment() {
        let ns = string as NSString
        let range = selectedRange()
        let block = ns.lineRange(for: range)
        let source = ns.substring(with: block)
        let lines = source.components(separatedBy: "\n")
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !contentLines.isEmpty && contentLines.allSatisfy(Self.isCommentedLine)

        let transformed = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allCommented {
                return Self.removingCommentPrefix(from: line)
            }
            return Self.addingCommentPrefix(to: line)
        }.joined(separator: "\n")

        guard transformed != source else { return }
        replaceBlock(block, with: transformed)
    }

    private static func isCommentedLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("--")
    }

    /// 保留缩进，在缩进之后插入 `-- `。
    private static func addingCommentPrefix(to line: String) -> String {
        let indent = leadingWhitespace(of: line)
        return indent + "-- " + line.dropFirst(indent.count)
    }

    /// 保留缩进，去掉缩进之后的 `-- ` / `--`。
    private static func removingCommentPrefix(from line: String) -> String {
        let indent = leadingWhitespace(of: line)
        var body = Substring(line.dropFirst(indent.count))
        if body.hasPrefix("-- ") {
            body = body.dropFirst(3)
        } else if body.hasPrefix("--") {
            body = body.dropFirst(2)
        }
        return indent + body
    }

    // MARK: 缩进 / 反缩进

    /// `⌘]`：插入 `indentWidth` 个空格；有选区时作用于所有相交行，保留空行。
    func indentSelection() {
        let spaces = String(repeating: " ", count: max(1, indentWidth))
        let range = selectedRange()
        if range.length == 0 {
            if replaceCharacters(in: range, with: spaces) {
                setSelectedRange(NSRange(location: range.location + (spaces as NSString).length, length: 0))
            }
            return
        }

        let ns = string as NSString
        let block = ns.lineRange(for: range)
        let source = ns.substring(with: block)
        let indented = source
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : spaces + $0 }
            .joined(separator: "\n")
        guard indented != source else { return }
        replaceBlock(block, with: indented)
    }

    /// `⌘[`：按 `indentWidth` 去掉行首空格；有选区时作用于所有相交行。
    func outdentSelection() {
        let ns = string as NSString
        let range = selectedRange()
        let block = ns.lineRange(for: range)
        let source = ns.substring(with: block)
        let outdented = Self.removingLeadingSpaces(from: source, width: max(1, indentWidth))
        guard outdented != source else { return }
        replaceBlock(block, with: outdented)
    }

    private static func removingLeadingSpaces(from source: String, width: Int) -> String {
        source
            .components(separatedBy: "\n")
            .map { line -> String in
                var text = Substring(line)
                var removed = 0
                while removed < width, text.first == " " {
                    text = text.dropFirst()
                    removed += 1
                }
                return String(text)
            }
            .joined(separator: "\n")
    }

    // MARK: 文本替换（进入撤销栈）

    /// 用 `shouldChangeText` + `textStorage` + `didChangeText` 替换一段文本，
    /// 让 `NSTextView` 的撤销管理器记录这次修改。
    @discardableResult
    private func replaceCharacters(in range: NSRange, with replacement: String) -> Bool {
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        return true
    }

    /// 替换整段（一个或多个整行）并把选区落在替换后的文本上。
    private func replaceBlock(_ block: NSRange, with transformed: String) {
        guard replaceCharacters(in: block, with: transformed) else { return }
        setSelectedRange(NSRange(location: block.location, length: (transformed as NSString).length))
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }
}

// MARK: - 菜单命令桥

/// 菜单项把编辑器动作发给第一响应者（`SQLEditorTextView`）。
///
/// 返回值表示是否有响应对应动作；`TableLiteApp` 用它在没有编辑器时回退到标签导航
/// （`⌘[` / `⌘]` 的通用含义，见 `specs/02-workspace.md` §9）。
@MainActor
enum SQLEditorCommands {
    static func toggleComment() -> Bool {
        NSApp.sendAction(#selector(SQLEditorTextView.tableLiteToggleComment(_:)), to: nil, from: nil)
    }

    static func indent() -> Bool {
        NSApp.sendAction(#selector(SQLEditorTextView.tableLiteIndentSelection(_:)), to: nil, from: nil)
    }

    static func outdent() -> Bool {
        NSApp.sendAction(#selector(SQLEditorTextView.tableLiteOutdentSelection(_:)), to: nil, from: nil)
    }
}
