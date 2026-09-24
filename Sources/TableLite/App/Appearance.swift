import AppKit
import SwiftUI

/// 外观偏好的 UI 侧映射与动态色工具（`docs/tech-designs/06-ui-layer.md` §9）。
///
/// Core 层的 `AppearanceMode` 不依赖 SwiftUI / AppKit；到 `ColorScheme` / `NSAppearance`
/// 的映射、以及自定义色的动态化工具统一放在这里，供 App / Features 共用。

extension AppearanceMode {

    /// `preferredColorScheme` 入参；`nil` 表示跟随系统。
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    /// `NSApp.appearance` 的值；`nil` 表示跟随系统。
    ///
    /// 让 AppKit 自建窗口（`NSAlert`、`NSOpenPanel`、快速查看 `NSPanel`）也一起切换，
    /// 这些窗口不看 SwiftUI 的 `preferredColorScheme`。
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

extension NSColor {

    /// 保留动态性的 `withAlphaComponent`。
    ///
    /// `NSColor.withAlphaComponent` 会把动态系统色**解析成当前外观下的固定值**，
    /// 之后再切换外观不会跟着变（`06-ui-layer.md` §9）。
    /// 这里用动态 provider 包一层，让它在每次绘制时按当时的 `NSAppearance` 重新解析。
    func withDynamicAlpha(_ alpha: CGFloat) -> NSColor {
        guard alpha < 1 else { return self }
        return NSColor(name: nil) { _ in self.withAlphaComponent(alpha) }
    }
}
