import AppKit
import SwiftUI

// MARK: - 快速查看面板
//
// `NSPanel` + SwiftUI 内容。面板独立浮动、可调整、`Esc` 关闭。
// 见 docs/tech-designs/06-ui-layer.md §1、specs/03-data-browsing.md §8。

/// 捕获 `Esc` 并回调。
final class QuickLookPanel: NSPanel {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class QuickLookPanelController: NSObject, NSWindowDelegate {

    private var panel: QuickLookPanel?
    private var model: QuickLookContentModel?

    /// 打开或复用一个快速查看面板。
    func show(title: String,
              kind: ColumnKind,
              value: CellValue?,
              isLoading: Bool,
              error: String?) {
        let content = QuickLookContentModel(title: title, kind: kind, value: value,
                                            isLoading: isLoading, error: error)
        model = content

        if let panel {
            if let hosting = panel.contentView as? NSHostingView<QuickLookView> {
                hosting.rootView = QuickLookView(model: content)
            }
            panel.title = "快速查看 · \(title)"
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let newPanel = QuickLookPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "快速查看 · \(title)"
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.minSize = NSSize(width: 420, height: 300)
        newPanel.onEscape = { [weak self] in self?.close() }
        newPanel.delegate = self
        newPanel.contentView = NSHostingView(rootView: QuickLookView(model: content))
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
    }

    /// 异步加载完成后更新内容。
    func update(value: CellValue?, isLoading: Bool, error: String?) {
        guard let model else { return }
        model.value = value
        model.isLoading = isLoading
        model.error = error
    }

    func close() {
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
        panel = nil
    }
}
