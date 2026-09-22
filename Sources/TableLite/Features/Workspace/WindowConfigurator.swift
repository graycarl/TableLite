import SwiftUI
import AppKit

/// 把 SwiftUI 窗口接上 `NSWindow`，用于设置 frame 自动保存名（`02-persistence.md` §7）。
///
/// 单窗口应用：`WorkspaceStateStore.windowFrameAutosaveName` 交给 AppKit，
/// 这样下次启动能恢复窗口位置与大小。
struct WindowConfigurator: NSViewRepresentable {

    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorView()
        view.autosaveName = autosaveName
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ConfiguratorView else { return }
        view.autosaveName = autosaveName
        view.apply()
    }

    /// 纯 AppKit 视图：窗口挂载后设置 autosave name，避免在 SwiftUI 更新里做异步派发。
    private final class ConfiguratorView: NSView {

        var autosaveName = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            if window.frameAutosaveName != autosaveName {
                window.setFrameAutosaveName(autosaveName)
            }
        }
    }
}
