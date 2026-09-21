import AppKit
import SwiftUI

// MARK: - SQL 编辑器（SwiftUI ↔ AppKit 桥）
//
// `NSScrollView` + `SQLEditorTextView` + `LineNumberRulerView`。
// 硬约束：必须关闭全部智能替换（见 `docs/tech-designs/10-query-editor.md` §2、AGENTS.md 坑 1）。
//
// 职责划分（docs/tech-designs/06-ui-layer.md §4）：
// - SwiftUI 侧只声明参数与回调；
// - Coordinator 实现 `NSTextViewDelegate` 并把选择 / 文本变化转成回调；
// - `SQLEditorTextView` / `LineNumberRulerView` 负责交互与渲染。

struct SQLEditorView: NSViewRepresentable {

    @Binding var text: String
    @Binding var selectedRange: NSRange
    @Binding var cursorLocation: Int

    var fontName: String
    var fontSize: Double
    var indentWidth: Int
    var showLineNumbers: Bool
    var highlightCurrentStatement: Bool
    var isEditable: Bool

    var onExecute: () -> Void
    var onExecuteAll: () -> Void
    var onStop: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: 字体

    static func editorFont(name: String, size: Double) -> NSFont {
        let pointSize = CGFloat(max(9, min(size, 48)))
        if !name.isEmpty, let font = NSFont(name: name, size: pointSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    // MARK: NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = SQLEditorTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                         textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isSelectable = true
        textView.isEditable = isEditable
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsDocumentBackgroundColorChange = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = [.font: SQLEditorView.editorFont(name: fontName, size: fontSize),
                                     .foregroundColor: NSColor.labelColor]

        // 硬约束：全部智能替换 / 拼写 / 数据检测必须关闭，否则 SQL 里的
        // `'` 会变弯引号、`--` 会变长破折号。见 AGENTS.md 坑 1。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.enabledTextCheckingTypes = 0

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.installCallbacks()
        context.coordinator.observeScrollingIfNeeded()
        context.coordinator.applySettings()
        context.coordinator.setInitialText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.installCallbacks()
        coordinator.applySettings()
        coordinator.applyFontIfNeeded()
        coordinator.syncExternalText()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: SQLEditorView
        weak var textView: SQLEditorTextView?
        weak var scrollView: NSScrollView?
        weak var ruler: LineNumberRulerView?
        var highlighter: SQLHighlighter?

        private var lastEditedRange: NSRange?
        private var lastFontKey: String?
        private var isApplying = false
        private var isEditableApplied: Bool?
        private var observingScroll = false

        init(_ parent: SQLEditorView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observeScrollingIfNeeded() {
            guard !observingScroll, let scrollView else { return }
            observingScroll = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(boundsDidChange(_:)),
                                                   name: NSView.boundsDidChangeNotification,
                                                   object: scrollView.contentView)
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            ruler?.needsDisplay = true
        }

        // MARK: 配置

        func installCallbacks() {
            guard let textView else { return }
            textView.onExecute = { [weak self] in self?.parent.onExecute() }
            textView.onExecuteAll = { [weak self] in self?.parent.onExecuteAll() }
            textView.onStop = { [weak self] in self?.parent.onStop() }
            textView.indentWidth = max(1, parent.indentWidth)
        }

        func applySettings() {
            guard let textView else { return }
            if isEditableApplied != parent.isEditable {
                isEditableApplied = parent.isEditable
                textView.isEditable = parent.isEditable
            }

            if parent.showLineNumbers {
                if ruler == nil, let scrollView {
                    let ruler = LineNumberRulerView(textView: textView,
                                                    scrollView: scrollView,
                                                    fontSize: CGFloat(parent.fontSize))
                    scrollView.verticalRulerView = ruler
                    scrollView.hasVerticalRuler = true
                    scrollView.rulersVisible = true
                    self.ruler = ruler
                    ruler.recountLines()
                }
            } else if ruler != nil {
                scrollView?.verticalRulerView = nil
                scrollView?.hasVerticalRuler = false
                scrollView?.rulersVisible = false
                self.ruler = nil
            }

            let font = SQLEditorView.editorFont(name: parent.fontName, size: parent.fontSize)
            if highlighter == nil {
                highlighter = SQLHighlighter(font: font,
                                             highlightCurrentStatement: parent.highlightCurrentStatement)
            } else {
                highlighter?.highlightCurrentStatement = parent.highlightCurrentStatement
            }
            ruler?.updateFontSize(CGFloat(parent.fontSize))
        }

        func applyFontIfNeeded() {
            guard let textView else { return }
            let key = "\(parent.fontName)#\(parent.fontSize)"
            guard key != lastFontKey else { return }
            lastFontKey = key
            let font = SQLEditorView.editorFont(name: parent.fontName, size: parent.fontSize)
            textView.font = font
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
            highlighter?.update(font: font)
            rehighlight(editedRange: nil)
        }

        func setInitialText(_ value: String) {
            guard let textView else { return }
            isApplying = true
            if textView.string != value {
                textView.string = value
            }
            let length = (value as NSString).length
            let location = min(max(0, parent.cursorLocation), length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            isApplying = false
            lastFontKey = "\(parent.fontName)#\(parent.fontSize)"
            rehighlight(editedRange: nil)
        }

        func syncExternalText() {
            guard let textView else { return }
            guard textView.string != parent.text else { return }
            isApplying = true
            let selection = textView.selectedRange()
            textView.string = parent.text
            let length = (parent.text as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            isApplying = false
            rehighlight(editedRange: nil)
        }

        // MARK: 高亮

        func rehighlight(editedRange: NSRange?) {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string
            let current = currentStatementRange(in: text)
            isApplying = true
            highlighter?.highlight(storage, text: text, editedRange: editedRange, currentStatement: current)
            isApplying = false
            ruler?.currentStatementStartLine = current.map { Self.lineNumber(at: $0.location, in: text) }
            ruler?.recountLines()
        }

        private func currentStatementRange(in text: String) -> NSRange? {
            guard parent.highlightCurrentStatement else { return nil }
            let statements = StatementSplitter.split(text)
            guard let index = QueryTabLogic.statementIndex(atCursor: parent.cursorLocation,
                                                           in: statements) else { return nil }
            return statements[index].range
        }

        private static func lineNumber(at offset: Int, in text: String) -> Int {
            let ns = text as NSString
            let clamped = max(0, min(offset, ns.length))
            var line = 1
            var index = 0
            while index < clamped {
                if ns.character(at: index) == 0x0A { line += 1 }
                index += 1
            }
            return line
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView, !isApplying else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            rehighlight(editedRange: lastEditedRange)
            lastEditedRange = nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !isApplying else { return }
            let range = textView.selectedRange()
            if parent.selectedRange != range {
                parent.selectedRange = range
            }
            if parent.cursorLocation != range.location {
                parent.cursorLocation = range.location
            }
            // 光标移动只需刷新「当前语句」背景，不重扫 token。
            if let storage = textView.textStorage, let highlighter {
                let current = currentStatementRange(in: textView.string)
                isApplying = true
                highlighter.applyCurrentStatement(storage, currentStatement: current)
                isApplying = false
                ruler?.currentStatementStartLine = current.map {
                    Self.lineNumber(at: $0.location, in: textView.string)
                }
            }
        }

        func textView(_ textView: NSTextView,
                      shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            let replacementLength = (replacementString as NSString? ?? "").length
            lastEditedRange = NSRange(location: affectedCharRange.location, length: replacementLength)
            return true
        }
    }
}
