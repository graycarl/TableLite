import SwiftUI

/// 连接颜色的界面色板。
///
/// `ConnectionColor` 只有中文名（Core 层不含 UI 依赖），到 `Color` 的映射放在这里，
/// 供连接列表与连接表单共用。
extension ConnectionColor {
    /// 连接颜色 → SwiftUI 颜色。`none` 不画颜色带，用透明表示。
    var swiftUIColor: Color {
        switch self {
        case .none: return .clear
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    /// 列表 / 表单色板：`none` 用中性灰点占位，而不是透明。
    var swatchColor: Color {
        self == .none ? Color.secondary.opacity(0.35) : swiftUIColor
    }
}
