import SwiftUI
import AppKit

/// 全局设计系统（`docs/tech-designs/06-ui-layer.md` §10）。
///
/// 间距 / 圆角只从这里取，按钮只用三档：主操作 `.borderedProminent`、
/// 窗口工具栏按钮（系统样式）、次级操作 `.subtle`。新视图不要引入刻度外的魔法数。

/// 间距刻度：4 / 6 / 8 / 10 / 12 / 16 / 20。
enum AppSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let s: CGFloat = 8
    static let m: CGFloat = 10
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
}

/// 圆角刻度：4 / 6 / 8。
enum AppRadius {
    static let s: CGFloat = 4
    static let m: CGFloat = 6
    static let l: CGFloat = 8
}


/// 字号刻度：正文 13 / 次要 12 / 说明 11 / 标题 15。
enum AppFont {
    static let body = Font.system(size: 13)
    static let secondary = Font.system(size: 12)
    static let caption = Font.system(size: 11)
}

/// 表面层级：侧栏 / 内容 / 字段栏 / 横条 / 表头 / 行分隔线。
///
/// 不用 `windowBackgroundColor` / `textBackgroundColor` 直接当层级——浅色下它们几乎都是白色，
/// 侧栏、网格、字段栏会黏成一片。这里显式给出浅色/深色两份值，切换外观时动态解析。
enum AppNSColor {
    static let sidebar = NSColor.dynamic(
        light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.094, green: 0.094, blue: 0.102, alpha: 1)
    )
    static let content = NSColor.dynamic(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1)
    )
    static let inspector = NSColor.dynamic(
        light: NSColor(srgbRed: 0.969, green: 0.969, blue: 0.976, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.125, blue: 0.137, alpha: 1)
    )
    static let bar = NSColor.dynamic(
        light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1),
        dark: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.157, alpha: 1)
    )
    static let gridHeader = NSColor.dynamic(
        light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.973, alpha: 1),
        dark: NSColor(srgbRed: 0.149, green: 0.149, blue: 0.161, alpha: 1)
    )
    static let rowAlternate = NSColor.dynamic(
        light: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.953, alpha: 1),
        dark: NSColor(srgbRed: 0.157, green: 0.157, blue: 0.169, alpha: 1)
    )
    static let rowSeparator = NSColor.dynamic(
        light: NSColor(srgbRed: 0.902, green: 0.902, blue: 0.914, alpha: 1),
        dark: NSColor(srgbRed: 0.176, green: 0.176, blue: 0.192, alpha: 1)
    )
    /// 列之间的竖线：比行分隔线再淡一档，免得整张网格碎成一片格子。
    static let cellSeparator = NSColor.dynamic(
        light: NSColor(srgbRed: 0.909, green: 0.909, blue: 0.921, alpha: 1),
        dark: NSColor(srgbRed: 0.169, green: 0.169, blue: 0.184, alpha: 1)
    )
}

enum AppColor {
    static let sidebar = Color(nsColor: AppNSColor.sidebar)
    static let content = Color(nsColor: AppNSColor.content)
    static let inspector = Color(nsColor: AppNSColor.inspector)
    static let bar = Color(nsColor: AppNSColor.bar)
    static let rowSeparator = Color(nsColor: AppNSColor.rowSeparator)
}

/// 尺寸刻度：表格行高、侧栏行高、工具栏控件高度。
enum AppMetrics {
    static let tableRowHeight: CGFloat = 26
}

/// 次级操作按钮（按钮第三档，`06-ui-layer.md` §10）。
///
/// 文字按钮：默认无底色，悬停出淡底，按下加深，禁用变淡。
/// 用于各横条里的非主操作（打开 / 另存为 / 重置 / 筛选 / 列 / 导出 / 统计 …），
/// 替代系统默认的灰底 pill 与蓝色 borderless 混排。
struct SubtleButtonStyle: ButtonStyle {

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(controlSize == .small ? .callout : .body)
            .foregroundStyle(.primary)
            .padding(.horizontal, AppSpacing.s)
            .padding(.vertical, controlSize == .small ? 2 : AppSpacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.m)
                    .fill(Color.primary.opacity(backgroundOpacity(configuration)))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    private func backgroundOpacity(_ configuration: Configuration) -> Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.14 }
        return isHovering ? 0.08 : 0
    }
}

extension ButtonStyle where Self == SubtleButtonStyle {

    /// 次级操作按钮：`.buttonStyle(.subtle)`。
    static var subtle: SubtleButtonStyle { SubtleButtonStyle() }
}
