import AppKit

// MARK: - SQL 语法高亮
//
// 基于 `SQLLexer.tokenize` 把 token 映射到颜色（`SQLTokenKind`），跟随系统深浅。
// 见 docs/tech-designs/10-query-editor.md §3。
//
// 增量策略（简单可靠优先）：
// - 每次编辑只对「受影响段落」（paragraph range）重新分词并覆盖属性；
// - 段落起点若落在未闭合的多行注释 / 字符串 / 反引号里，退回全量着色；
// - 光标所在语句整段加一层极淡背景（`StatementSplitter`，随光标移动只更新背景）。

@MainActor
final class SQLHighlighter {

    /// 颜色主题。全部用系统语义色，自动随系统深浅切换。
    struct Theme {
        var plainText: NSColor
        var keyword: NSColor
        var function: NSColor
        var type: NSColor
        var string: NSColor
        var backtick: NSColor
        var number: NSColor
        var comment: NSColor
        var variable: NSColor
        var parameter: NSColor
        var operatorSymbol: NSColor
        var punctuation: NSColor
        var identifier: NSColor
        var currentStatementBackground: NSColor

        static func system() -> Theme {
            Theme(
                plainText: .labelColor,
                keyword: .systemBlue,
                function: .systemPurple,
                type: .systemTeal,
                string: .systemRed,
                backtick: .systemBrown,
                number: .systemOrange,
                comment: .secondaryLabelColor,
                variable: .systemIndigo,
                parameter: .systemPink,
                operatorSymbol: .systemGray,
                punctuation: .secondaryLabelColor,
                identifier: .labelColor,
                // 极淡背景：用选区色降透明度，深浅两种外观下都自然
                currentStatementBackground: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10)
            )
        }
    }

    private var font: NSFont
    private var theme: Theme = .system()
    var highlightCurrentStatement: Bool

    init(font: NSFont, highlightCurrentStatement: Bool) {
        self.font = font
        self.highlightCurrentStatement = highlightCurrentStatement
    }

    func update(font: NSFont) {
        self.font = font
    }

    // MARK: 对外入口

    /// 着色。`editedRange` 为 nil 时全量重扫，否则只重扫受影响段落。
    func highlight(_ storage: NSTextStorage,
                   text: String,
                   editedRange: NSRange?,
                   currentStatement: NSRange?) {
        let ns = text as NSString
        guard storage.length == ns.length else { return }
        let full = NSRange(location: 0, length: storage.length)

        if let editedRange, storage.length > 0 {
            let clamped = clamp(editedRange, length: storage.length)
            let paragraph = paragraphRange(around: clamped, in: ns)
            let safeParagraph = clamp(paragraph, length: storage.length)
            if stateIsClean(before: safeParagraph.location, in: ns) {
                applyBase(storage, range: safeParagraph)
                let sub = ns.substring(with: safeParagraph)
                let tokens = SQLLexer.tokenize(sub)
                apply(tokens: tokens, to: storage, offset: safeParagraph.location, source: sub)
            } else {
                applyFull(storage, text: text)
            }
        } else {
            applyFull(storage, text: text)
        }

        applyCurrentStatement(storage, currentStatement: currentStatement, fullRange: full)
    }

    /// 只更新「当前语句」背景（光标移动时调用，不重扫 token）。
    func applyCurrentStatement(_ storage: NSTextStorage, currentStatement: NSRange?) {
        applyCurrentStatement(storage,
                              currentStatement: currentStatement,
                              fullRange: NSRange(location: 0, length: storage.length))
    }

    // MARK: 私有

    private func applyFull(_ storage: NSTextStorage, text: String) {
        let full = NSRange(location: 0, length: storage.length)
        applyBase(storage, range: full)
        let tokens = SQLLexer.tokenize(text)
        apply(tokens: tokens, to: storage, offset: 0, source: text)
    }

    private func applyBase(_ storage: NSTextStorage, range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.setAttributes([.font: font, .foregroundColor: theme.plainText], range: range)
    }

    private func apply(tokens: [SQLToken], to storage: NSTextStorage, offset: Int, source: String) {
        for token in tokens {
            let range = NSRange(location: token.range.location + offset, length: token.range.length)
            guard range.length > 0, NSMaxRange(range) <= storage.length else { continue }
            storage.addAttributes(attributes(for: token.kind), range: range)
        }
    }

    private func attributes(for kind: SQLTokenKind) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        switch kind {
        case .keyword: color = theme.keyword
        case .function: color = theme.function
        case .type: color = theme.type
        case .string: color = theme.string
        case .backtick: color = theme.backtick
        case .number: color = theme.number
        case .comment: color = theme.comment
        case .variable: color = theme.variable
        case .parameter: color = theme.parameter
        case .operatorSymbol: color = theme.operatorSymbol
        case .punctuation: color = theme.punctuation
        case .identifier: color = theme.identifier
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if kind == .comment {
            attributes[.obliqueness] = 0.08
        }
        return attributes
    }

    private func applyCurrentStatement(_ storage: NSTextStorage,
                                       currentStatement: NSRange?,
                                       fullRange: NSRange) {
        guard fullRange.length > 0 else { return }
        storage.removeAttribute(.backgroundColor, range: fullRange)
        guard highlightCurrentStatement, let currentStatement else { return }
        let range = clamp(currentStatement, length: storage.length)
        guard range.length > 0 else { return }
        storage.addAttribute(.backgroundColor, value: theme.currentStatementBackground, range: range)
    }

    /// 受影响区间横跨的段落范围。
    private func paragraphRange(around range: NSRange, in ns: NSString) -> NSRange {
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = min(range.location, ns.length)
        let startParagraph = ns.paragraphRange(for: NSRange(location: start, length: 0))
        guard range.length > 0 else { return startParagraph }
        let tailLocation = max(start, min(NSMaxRange(range) - 1, ns.length - 1))
        let endParagraph = ns.paragraphRange(for: NSRange(location: tailLocation, length: 0))
        return NSUnionRange(startParagraph, endParagraph)
    }

    /// 段落起点是否处于「正常」词法状态：前文最后一个 token 若延伸到起点且是
    /// 注释 / 字符串 / 反引号，说明多行 token 未闭合，独立重扫该段不可靠。
    private func stateIsClean(before offset: Int, in ns: NSString) -> Bool {
        guard offset > 0 else { return true }
        let clamped = min(offset, ns.length)
        guard clamped > 0 else { return true }
        let prefix = ns.substring(to: clamped)
        guard let last = SQLLexer.tokenize(prefix).last else { return true }
        guard NSMaxRange(last.range) >= clamped else { return true }
        switch last.kind {
        case .comment, .string, .backtick:
            return false
        default:
            return true
        }
    }

    private func clamp(_ range: NSRange, length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        let available = max(0, length - location)
        return NSRange(location: location, length: min(range.length, available))
    }
}
