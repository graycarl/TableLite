import SwiftUI

/// 状态指示器的形态（`specs/01-connections.md` §4）。
///
/// 抽成纯枚举便于单测：连接中是转圈，其余是圆点，整套界面（连接列表、
/// 工具栏连接下拉、状态栏）含义一致。
enum SessionStatusIndicatorStyle: Equatable {
    /// 正在建立隧道或连接数据库。
    case spinner
    /// 其余状态：用颜色区分的圆点。
    case dot
}

extension SessionConnectionState {
    /// 状态指示器的形态（`specs/01-connections.md` §4：连接中 = 转圈）。
    var indicatorStyle: SessionStatusIndicatorStyle {
        switch self {
        case .connecting: return .spinner
        case .connected, .failed, .disconnected, .recycled: return .dot
        }
    }

    /// 状态点颜色（`specs/02-workspace.md` §7）：正常绿、隧道重建黄、断开红。
    var indicatorColor: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected, .recycled: return Color.secondary
        }
    }
}

/// 会话状态指示器：连接中转圈，其余为彩色圆点。
///
/// 与连接列表的 `ConnectionStatusIndicator` 保持同一套含义
/// （`specs/01-connections.md` §4）。
struct SessionStatusDot: View {
    let state: SessionConnectionState

    var body: some View {
        Group {
            switch state.indicatorStyle {
            case .spinner:
                ProgressView()
                    .controlSize(.small)
            case .dot:
                Circle()
                    .fill(state.indicatorColor)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
    }
}
