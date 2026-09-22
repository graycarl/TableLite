import SwiftUI

extension SessionConnectionState {
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

/// 会话状态点。
struct SessionStatusDot: View {
    let state: SessionConnectionState

    var body: some View {
        Circle()
            .fill(state.indicatorColor)
            .frame(width: 8, height: 8)
    }
}
