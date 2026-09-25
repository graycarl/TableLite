import SwiftUI

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
