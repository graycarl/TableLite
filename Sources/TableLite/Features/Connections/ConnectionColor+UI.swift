import SwiftUI

/// 连接颜色的界面色板。
///
/// `ConnectionColor` 只有中文名（Core 层不含 UI 依赖），到 `Color` 的映射放在这里，
/// 供连接列表与连接表单共用。
extension ConnectionColor {
    var swatchColor: Color {
        switch self {
        case .none: return Color.secondary.opacity(0.35)
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}
