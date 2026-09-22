import SwiftUI

/// 会话不可用时的遮罩（`specs/02-workspace.md` §10、`specs/01-connections.md` §3/§5）。
///
/// - 已断开 / 已回收 / 连接失败：覆盖内容区，显示原因与「重新连接」；
/// - 连接失败：按 `ConnectFailure` 分别展示步骤、底层错误原文与建议。
struct SessionStateOverlay: View {

    let session: ConnectionSession

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            VStack(spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 30))
                    .foregroundStyle(symbolColor)
                Text(title)
                    .font(.title3)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 520)
                }
                if let suggestion {
                    Text(suggestion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                if !isConnecting {
                    Button("重新连接") { reconnect() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
    }

    private var symbolName: String {
        if case .failed = session.state { return "exclamationmark.triangle" }
        return "bolt.horizontal.circle"
    }

    private var symbolColor: Color {
        if case .failed = session.state { return .red }
        return .secondary
    }

    private var title: String {
        switch session.state {
        case .failed(let failure): return failure.title
        case .recycled: return "连接已回收"
        case .disconnected: return "连接已断开"
        case .connecting(let step): return step.progressText
        case .connected: return ""
        }
    }

    private var detail: String? {
        switch session.state {
        case .failed(let failure):
            return failure.underlyingMessage.isEmpty ? failure.explanation : failure.underlyingMessage
        case .recycled:
            return "该连接因空闲被回收以释放服务器连接，标签内容仍然保留。"
        case .disconnected:
            return "点击下方按钮重新连接；暂存的改动不会丢失。"
        default:
            return nil
        }
    }

    private var suggestion: String? {
        session.state.failure?.suggestion
    }

    private var isConnecting: Bool {
        if case .connecting = session.state { return true }
        return false
    }

    private func reconnect() {
        Task { try? await environment.sessionManager.reconnect(id: session.id) }
    }
}
