import SwiftUI

/// 连接失败的错误正文：原始错误 + 中文解释 + 排查建议。
///
/// 规则见 `specs/12-feedback.md` §5：服务器原始错误不翻译、不截断；
/// SSH 的 `stderr` 尾部由 `ConnectFailure.underlyingMessage` 原样带出（`specs/01-connections.md` §3、§4）。
struct ConnectionFailureBody: View {
    let failure: ConnectFailure

    /// 主机指纹变化单独高亮（`specs/10-ssh-tunnel.md` §4）。
    private var isHostKeyChanged: Bool {
        failure.sshError?.isHostKeyChanged == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isHostKeyChanged {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                    Text("主机指纹变化")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            }
            if !failure.underlyingMessage.isEmpty {
                Text(failure.underlyingMessage)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(failure.explanation)
                .font(.callout)
            if let suggestion = failure.suggestion {
                Text(suggestion)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 连接失败的详情面板（列表里的「查看详情」与连接失败时弹出）。
///
/// `specs/01-connections.md` §4：失败发生在哪一步、原始错误文本、建议的排查方向。
struct ConnectionFailureDetailView: View {
    let failure: ConnectFailure
    let connectionName: String?
    let onReconnect: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failure.title)
                .font(.headline)
            HStack(spacing: 12) {
                Text("失败步骤：\(failure.step.displayName)")
                if let connectionName {
                    Text("连接：\(connectionName)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            ConnectionFailureBody(failure: failure)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if let onReconnect {
                    Button("重新连接") { onReconnect() }
                }
                Button("关闭") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .topLeading)
        .frame(minHeight: 260)
    }
}
