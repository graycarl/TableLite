import SwiftUI

/// 「测试连接」的分步结果面板（`specs/01-connections.md` §3）。
///
/// 步骤依次为 SSH 隧道 → MySQL 连接 → 读取服务器信息；成功 ✓、失败 ✗、未走到或未启用则跳过。
/// 失败时原样展示底层错误（SSH 含 `stderr` 尾部）与排查建议。
struct ConnectionTestView: View {

    let sshEnabled: Bool
    let report: ConnectionTestReport?
    let isTesting: Bool
    let onCancel: () -> Void
    let onSaveAndConnect: (() -> Void)?

    /// 未出结果时按「还没轮到」渲染，出结果后用 Core 的报告。
    private var steps: [ConnectionTestStep] {
        if let report { return report.steps }
        return ConnectStep.allCases
            .filter { $0 != .sshTunnel || sshEnabled }
            .map { ConnectionTestStep(step: $0, outcome: .pending) }
    }

    /// 正在探测的那一步：只给第一个 pending 步骤转圈，其余显示等待中的虚线圈。
    private var runningStep: ConnectStep? {
        steps.first { $0.outcome == .pending }?.step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("测试连接")
                .font(.headline)
                .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(steps) { step in
                        stepRow(step)
                    }
                    if let unresolved = report?.unresolvedDatabase, !unresolved.isEmpty {
                        Text("连接配置里的数据库 \(unresolved) 不存在；连上后会选中第一个可访问的库。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack {
                if isTesting {
                    Button("取消") { onCancel() }
                } else {
                    Button("关闭") { onCancel() }
                }
                Spacer()
                if report?.succeeded == true, let onSaveAndConnect {
                    Button("保存并连接") { onSaveAndConnect() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 540)
        .frame(minHeight: 300)
    }

    // MARK: - 单步

    @ViewBuilder
    private func stepRow(_ step: ConnectionTestStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                icon(for: step)
                Text(title(for: step))
                    .font(.body)
            }
            if step.step == .serverInfo, step.isSuccess, let info = report?.serverInfo {
                Text(serverLine(info))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
            if let failure = step.failure {
                ConnectionFailureBody(failure: failure)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private func icon(for step: ConnectionTestStep) -> some View {
        switch step.outcome {
        case .pending:
            if isTesting, step.step == runningStep {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func title(for step: ConnectionTestStep) -> String {
        switch step.outcome {
        case .pending:
            return step.step.progressText
        case .success:
            switch step.step {
            case .sshTunnel: return "SSH 隧道建立成功"
            case .mysql: return "MySQL 连接成功"
            case .serverInfo: return "读取到服务器信息"
            }
        case .skipped:
            return step.step == .sshTunnel ? "已跳过 SSH 隧道（未启用）" : "\(step.step.displayName)：已跳过"
        case .failure(let failure):
            return failure.title
        }
    }

    private func serverLine(_ info: ServerInfo) -> String {
        let charset = info.connectionCharset.isEmpty ? info.charset : info.connectionCharset
        return charset.isEmpty ? info.version : "\(info.version) · \(charset)"
    }
}
