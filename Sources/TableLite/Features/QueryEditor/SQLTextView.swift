import SwiftUI
import AppKit

/// SQL 编辑器文本视图（`docs/tech-designs/10-query-editor.md` §2）。
///
/// `NSScrollView` + `NSTextView` 桥接，带行号栏、语法高亮、当前语句背景、自动缩进。
///
/// **硬约束：必须关闭全部智能替换** —— 智能引号、智能破折号、文本替换、拼写纠正、数据检测。
/// 不关的话 SQL 里的 `'` 会变成弯引号、字符串里的 `--` 会变成长破折号（AGENTS 坑 §1）。
///
/// 组件同时服务三处：查询编辑器、字段栏长文本大窗口（L29）、预览 SQL 面板（L30）。
/// 只读场景把 `isEditable` 置 `false`。
struct SQLTextView: NSViewRepresentable {

    @Binding var text: String
    var isEditable: Bool = true
    var fontName: String = ""
    var fontSize: Double = 13
    var indentWidth: Int = 4
    var showLineNumbers: Bool = true
    var highlightCurrentStatement: Bool = true
    /// 是否做 SQL 语法着色；字段栏长文本（L29）等非 SQL 正文置 `false`，只保留行号与查找。
    var syntaxHighlighting: Bool = true
    /// 单行场景（预览 SQL 之外的短文本）关掉换行。
    var wrapsLines: Bool = true
    /// `⌘F` 请求计数器：变化时弹出系统查找条。
    var findRequestToken: Int = 0
    /// 注释切换 / 缩进 / 反缩进命令；`token` 变化时执行一次。
    var command: SQLTextViewCommand?
    var onTextChange: ((String) -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onTextChange: onTextChange,
            onSelectionChange: onSelectionChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextEditorView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = Self.font(name: fontName, size: fontSize)
        textView.indentWidth = max(1, indentWidth)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : [.width, .height]
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        Self.disableSmartSubstitutions(textView)

        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.highlightsCurrentStatement = highlightCurrentStatement
        context.coordinator.highlightsSyntax = syntaxHighlighting
        context.coordinator.applyInitialHighlight()

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        ruler.highlighter = context.coordinator.highlighter
        ruler.isHidden = !showLineNumbers
        context.coordinator.ruler = ruler
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showLineNumbers
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable
        textView.indentWidth = max(1, indentWidth)
        let resolvedFont = Self.font(name: fontName, size: fontSize)
        let fontChanged = textView.font != resolvedFont
        if fontChanged {
            textView.font = resolvedFont
            context.coordinator.applyFont(resolvedFont)
        }
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.highlightsCurrentStatement = highlightCurrentStatement
        context.coordinator.highlightsSyntax = syntaxHighlighting

        if context.coordinator.lastText != text, textView.string != text {
            context.coordinator.replaceText(text, in: textView)
        }

        if context.coordinator.lastCommandToken != command?.token, let command {
            context.coordinator.lastCommandToken = command.token
            context.coordinator.apply(command: command.command, in: textView)
        }

        if context.coordinator.lastFindToken != findRequestToken {
            context.coordinator.lastFindToken = findRequestToken
            context.coordinator.showFindBar(in: textView)
        }

        if let ruler = context.coordinator.ruler {
            ruler.isHidden = !showLineNumbers
            scrollView.rulersVisible = showLineNumbers
        }
        context.coordinator.ruler?.needsDisplay = true
    }

    // MARK: 工具

    static func font(name: String, size: Double) -> NSFont {
        let pointSize = max(8, CGFloat(size))
        if !name.isEmpty, let font = NSFont(name: name, size: pointSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    /// 关闭全部智能替换（AGENTS 坑 §1）。
    static func disableSmartSubstitutions(_ textView: NSTextView) {
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
    }

    // MARK: 协调器

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        private let text: Binding<String>
        var onTextChange: ((String) -> Void)?
        var onSelectionChange: ((NSRange) -> Void)?
        let highlighter = SQLSyntaxHighlighter()
        weak var textView: SQLTextEditorView?
        weak var ruler: LineNumberRulerView?
        var lastText: String = ""
        var lastFindToken = 0
        var lastCommandToken = -1
        var highlightsCurrentStatement = true
        var highlightsSyntax = true

        init(
            text: Binding<String>,
            onTextChange: ((String) -> Void)?,
            onSelectionChange: ((NSRange) -> Void)?
        ) {
            self.text = text
            self.onTextChange = onTextChange
            self.onSelectionChange = onSelectionChange
            self.lastText = text.wrappedValue
        }

        func applyInitialHighlight() {
            guard let textView, let storage = textView.textStorage else { return }
            highlighter.invalidate()
            _ = highlighter.refresh(text: textView.string)
            let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            highlighter.applySyntax(to: storage, from: 0, font: font, enabled: highlightsSyntax)
            highlighter.applyStatementHighlight(
                to: storage,
                textLength: (textView.string as NSString).length,
                cursor: textView.selectedRange().location,
                enabled: highlightsCurrentStatement
            )
            textView.setNeedsDisplay(textView.bounds)
        }

        /// 外部替换文本（例如打开脚本文件）。
        func replaceText(_ newText: String, in textView: NSTextView) {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.replaceCharacters(in: full, with: newText)
            lastText = newText
            highlighter.invalidate()
            refreshHighlight(full: true)
        }

        /// 字号 / 字体变化后重新应用样式。
        func applyFont(_ font: NSFont) {
            textView?.font = font
            refreshHighlight(full: true)
        }

        func refreshHighlight(full: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let value = textView.string
            if full || lastText != value {
                highlighter.invalidate()
            }
            _ = highlighter.refresh(text: value)
            let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            highlighter.applySyntax(to: storage, from: 0, font: font, enabled: highlightsSyntax)
            highlighter.applyStatementHighlight(
                to: storage,
                textLength: (value as NSString).length,
                cursor: textView.selectedRange().location,
                enabled: highlightsCurrentStatement
            )
            ruler?.needsDisplay = true
        }

        func showFindBar(in textView: NSTextView) {
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            textView.performFindPanelAction(item)
        }

        /// 应用注释切换 / 缩进 / 反缩进。
        func apply(command: SQLEditingCommand, in textView: NSTextView) {
            let indentWidth = (textView as? SQLTextEditorView)?.indentWidth ?? 4
            let selection = textView.selectedRange()
            let result: (text: String, selection: NSRange)
            switch command {
            case .toggleComment:
                result = SQLTextEditing.toggleComment(text: textView.string, selection: selection, indentWidth: indentWidth)
            case .indent:
                result = SQLTextEditing.indent(text: textView.string, selection: selection, indentWidth: indentWidth)
            case .dedent:
                result = SQLTextEditing.dedent(text: textView.string, selection: selection, indentWidth: indentWidth)
            }
            guard result.text != textView.string else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.replaceCharacters(in: full, with: result.text)
            textView.setSelectedRange(result.selection)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            lastText = value
            text.wrappedValue = value
            onTextChange?(value)
            if let storage = textView.textStorage {
                let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                let start = highlighter.refresh(text: value)
                highlighter.applySyntax(to: storage, from: start, font: font, enabled: highlightsSyntax)
                highlighter.applyStatementHighlight(
                    to: storage,
                    textLength: (value as NSString).length,
                    cursor: textView.selectedRange().location,
                    enabled: highlightsCurrentStatement
                )
            }
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onSelectionChange?(textView.selectedRange())
            if let storage = textView.textStorage {
                highlighter.applyStatementHighlight(
                    to: storage,
                    textLength: (textView.string as NSString).length,
                    cursor: textView.selectedRange().location,
                    enabled: highlightsCurrentStatement
                )
            }
            ruler?.needsDisplay = true
        }
    }
}

// MARK: - 文本视图子类

/// 处理 `Tab` / `⇧Tab` / 回车自动缩进。
final class SQLTextEditorView: NSTextView {

    var indentWidth = 4

    override func insertTab(_ sender: Any?) {
        insertIndent()
    }

    override func insertBacktab(_ sender: Any?) {
        removeIndent()
    }

    override func insertNewline(_ sender: Any?) {
        let nsText = string as NSString
        let location = selectedRange().location
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let line = nsText.substring(with: lineRange)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(indent, replacementRange: selectedRange())
        }
    }

    private func insertIndent() {
        let spaces = String(repeating: " ", count: max(1, indentWidth))
        insertText(spaces, replacementRange: selectedRange())
    }

    private func removeIndent() {
        let nsText = string as NSString
        let selection = selectedRange()
        let lineStart = nsText.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let current = selection.location - lineStart
        guard current > 0 else { return }
        // 光标前的连续空格最多删 `indentWidth` 个；不足则删到行首。
        var removable = 0
        while removable < min(indentWidth, current), nsText.character(at: selection.location - removable - 1) == 0x20 {
            removable += 1
        }
        guard removable > 0 else { return }
        let range = NSRange(location: selection.location - removable, length: removable)
        insertText("", replacementRange: range)
    }
}

// MARK: - 行号栏

/// 左侧行号栏（`docs/tech-designs/10-query-editor.md` §2），并标出当前语句起始行。
final class LineNumberRulerView: NSRulerView {

    weak var highlighter: SQLSyntaxHighlighter?

    private var textView: NSTextView? {
        scrollView?.documentView as? NSTextView
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.stroke()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let visibleRect = scrollView?.contentView.bounds ?? textView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let nsText = textView.string as NSString

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (textView.font?.pointSize ?? 13) - 1), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let accentAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.controlAccentColor,
        ]

        // 当前语句起始位置（用于把起始行号标成强调色）。
        let statementStart = highlighter?.statementRange?.location

        var lineNumber = 1
        if charRange.location > 0 {
            let prefix = nsText.substring(to: charRange.location)
            let newlines = prefix.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            lineNumber = newlines + 1
        }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, glyphRangeForLine, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRangeForLine.location)
            let numberText = "\(lineNumber)"
            let isStatementStart = statementStart == charIndex
            let size = (numberText as NSString).size(withAttributes: isStatementStart ? accentAttributes : attributes)
            let y = usedRect.minY + textView.textContainerInset.height + (usedRect.height - size.height) / 2
            let x = self.ruleThickness - size.width - 8
            (numberText as NSString).draw(
                at: NSPoint(x: x, y: y),
                withAttributes: isStatementStart ? accentAttributes : attributes
            )
            lineNumber += 1
        }
    }
}
