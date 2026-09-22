import SwiftUI
import AppKit

/// 纯文本编辑器（AppKit `NSTextView`）。
///
/// 用于字段栏的长文本 / JSON 内联编辑与展开窗口。**必须关闭全部智能替换**
/// （智能引号、智能破折号、文本替换、拼写纠正），否则 `'` 等字符会被系统改写
/// （见 `AGENTS.md` 坑 §1、`docs/tech-designs/10-query-editor.md` §2）。
struct PlainTextView: NSViewRepresentable {

    @Binding var text: String
    var isEditable: Bool
    var isMultiline: Bool
    var fontSize: Double
    /// 失焦或提交键（单行 `↩` / 多行 `⌘↩`）时调用。
    var onCommit: () -> Void
    /// `Esc` 取消时调用。
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditableTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        // 智能替换全部关闭（AGENTS 坑 §1）。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        textView.onCommit = onCommit
        textView.onCancel = onCancel
        textView.isMultiline = isMultiline
        textView.string = text
        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable
        textView.onCommit = onCommit
        textView.onCancel = onCancel
        textView.isMultiline = isMultiline
        // 只在非编辑状态下同步，避免打断输入。
        if !textView.isEditing, textView.string != text {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        private let text: Binding<String>
        private let onCommit: () -> Void
        private let onCancel: () -> Void
        weak var textView: EditableTextView?

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func textDidBeginEditing(_ notification: Notification) {
            textView?.isEditing = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            textView?.isEditing = false
            onCommit()
        }
    }
}

/// 支持提交 / 取消键的 `NSTextView`。
final class EditableTextView: NSTextView {

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var isMultiline = false
    var isEditing = false

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Esc：放弃本次编辑。
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        // ⌘↩：提交（单行 / 多行都适用）。
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        // 单行编辑器里 ↩ 即提交；多行里 ↩ 是换行（⇧↩ 换行）。
        if !isMultiline, flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
