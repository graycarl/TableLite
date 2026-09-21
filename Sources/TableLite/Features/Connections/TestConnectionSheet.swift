import SwiftUI
import os

// MARK: - 测试连接

/// 「测试连接」面板。按步骤展示 SSH 隧道 → MySQL → 服务器信息的结果，
/// 失败时原样展示底层错误。见 `specs/01-connections.md` §3。
///
/// 测试走的是与正式连接相同的 `ConnectionSession.open()` 代码路径，用完立即 `close()`，
/// 不写入 `SessionManager`、不写查询历史（`docs/tech-designs/05-session-management.md` §3.1）。
struct TestConnectionSheet: View {
    @StateObject private var model: TestConnectionViewModel

    let onSaveAndConnect: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false

    init(env: AppEnvironment,
         connection: Connection,
         password: String?,
         onSaveAndConnect: @escaping () async -> Bool) {
        _model = StateObject(wrappedValue: TestConnectionViewModel(connection: connection,
                                                                   password: password,
                                                                   env: env))
        self.onSaveAndConnect = onSaveAndConnect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("测试连接")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.steps) { step in
                        TestStepRow(step: step)
                    }
                    if let failure = model.failure {
                        FailureSummary(error: failure,
                                       rawOutput: model.rawOutput,
                                       showsRawOutput: model.showsRawOutput)
                    }
                    if let info = model.serverInfo {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("服务器版本：\(info.version)")
                            Text("字符集 \(info.charset) · 排序规则 \(info.collation)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack(spacing: 12) {
                Button("查看详细输出") { model.showsRawOutput.toggle() }
                    .disabled(model.rawOutput == nil)
                Spacer()
                Button("关闭") { dismiss() }
                Button("保存并连接") {
                    Task {
                        isSaving = true
                        let ok = await onSaveAndConnect()
                        isSaving = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isSuccess || isSaving)
            }
            .padding(20)
        }
        .frame(width: 560, height: 460)
        .task { await model.run() }
    }
}

// MARK: - 步骤行

private struct TestStepRow: View {
    let step: TestConnectionViewModel.Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.displayTitle)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch step.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - 失败详情

private struct FailureSummary: View {
    let error: MySQLError
    let rawOutput: String?
    let showsRawOutput: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let serverError = error.serverError {
                Text(serverError.formatted)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if let hint = serverError.chineseHint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if case .connect(_, let message, let detail) = error {
                Text(message)
                    .font(.callout)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text(error.title)
            }

            Text("测试连接不会改动数据。修正配置后可以重试。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsRawOutput, let rawOutput {
                ScrollView {
                    Text(rawOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - TestConnectionViewModel

/// 测试连接的运行时状态。分步结果由观察 `ConnectionSession.state` 得到。
@MainActor
final class TestConnectionViewModel: ObservableObject {

    enum StepStatus: Equatable {
        case pending
        case running
        case success
        case failure
    }

    struct Step: Identifiable {
        let id: String
        var title: String
        var status: StepStatus
        var detail: String?

        var displayTitle: String {
            switch status {
            case .pending, .running:
                return title
            case .success:
                return "\(title)成功"
            case .failure:
                return "\(title)失败"
            }
        }
    }

    @Published var steps: [Step]
    @Published var isRunning = false
    @Published var failure: MySQLError?
    @Published var serverInfo: ServerInfo?
    @Published var rawOutput: String?
    @Published var showsRawOutput = false

    private let connection: Connection
    private let password: String?
    private let env: AppEnvironment
    private var session: ConnectionSession?
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    private static let sshStepID = "ssh"
    private static let mysqlStepID = "mysql"
    private static let serverStepID = "serverInfo"

    init(connection: Connection, password: String?, env: AppEnvironment) {
        self.connection = connection
        self.password = password
        self.env = env

        var steps: [Step] = []
        if connection.ssh.enabled {
            steps.append(Step(id: Self.sshStepID, title: "SSH 隧道建立", status: .pending, detail: nil))
        }
        steps.append(Step(id: Self.mysqlStepID, title: "MySQL 连接", status: .pending, detail: nil))
        steps.append(Step(id: Self.serverStepID, title: "读取服务器信息", status: .pending, detail: nil))
        self.steps = steps
    }

    var isSuccess: Bool {
        serverInfo != nil && failure == nil && !isRunning
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        failure = nil
        rawOutput = nil
        showsRawOutput = false
        resetSteps()

        let session = ConnectionSession(connection: connection,
                                        password: password,
                                        credentials: env.credentials,
                                        preferences: env.preferences,
                                        consoleLog: env.consoleLog,
                                        drafts: nil,
                                        clock: env.clock,
                                        fileSystem: env.fileSystem)
        self.session = session

        let observation = Task { @MainActor [weak self] in
            for await state in session.$state.values {
                guard let self else { return }
                self.apply(state: state)
            }
        }

        do {
            try await session.open()
            serverInfo = session.serverInfo
            if let info = session.serverInfo {
                setDetail(Self.serverStepID, detail: "\(info.version) · \(info.charset)")
            }
            if connection.ssh.enabled, let tunnel = session.tunnel {
                if case .ready(let port) = await tunnel.state {
                    setDetail(Self.sshStepID, detail: "本地转发端口 127.0.0.1:\(port)")
                }
            }
            apply(state: .connected)
        } catch {
            let mapped = (error as? MySQLError) ?? MySQLError.internalError(error.localizedDescription)
            failure = mapped
            apply(error: mapped)
            rawOutput = await collectRawOutput(for: mapped, session: session)
        }

        observation.cancel()
        await session.close()
        self.session = nil
        isRunning = false
    }

    // MARK: 状态映射

    private func apply(state: ConnectionState) {
        switch state {
        case .disconnected:
            break

        case .connecting(let step):
            switch step {
            case .sshTunnel:
                setStatus(Self.sshStepID, .running)
            case .mysql:
                setStatus(Self.sshStepID, .success)
                setStatus(Self.mysqlStepID, .running)
            case .serverInfo:
                setStatus(Self.sshStepID, .success)
                setStatus(Self.mysqlStepID, .success)
                setStatus(Self.serverStepID, .running)
            }

        case .connected:
            setStatus(Self.sshStepID, .success)
            setStatus(Self.mysqlStepID, .success)
            setStatus(Self.serverStepID, .success)

        case .failed:
            break
        }
    }

    private func apply(error: MySQLError) {
        switch error {
        case .connect(let step, _, _):
            switch step {
            case .sshTunnel:
                setStatus(Self.sshStepID, .failure)
            case .mysql:
                setStatus(Self.sshStepID, .success)
                setStatus(Self.mysqlStepID, .failure)
            case .serverInfo:
                setStatus(Self.sshStepID, .success)
                setStatus(Self.mysqlStepID, .success)
                setStatus(Self.serverStepID, .failure)
            }
        default:
            setStatus(Self.mysqlStepID, .failure)
        }
    }

    private func collectRawOutput(for error: MySQLError, session: ConnectionSession) async -> String? {
        var parts: [String] = []
        if let serverError = error.serverError {
            parts.append(serverError.formatted)
        } else if case .connect(let step, let message, let detail) = error {
            parts.append("发生步骤：\(step.displayName)")
            parts.append(message)
            if let detail, !detail.isEmpty {
                parts.append(detail)
            }
        } else {
            parts.append(error.title)
        }

        if let tunnel = session.tunnel {
            let output = await tunnel.errorOutput
            if !output.isEmpty {
                parts.append("SSH 原始输出：\n\(output)")
            }
        }

        let joined = parts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    // MARK: 步骤更新

    private func resetSteps() {
        for index in steps.indices {
            steps[index].status = .pending
            steps[index].detail = nil
        }
    }

    private func setStatus(_ id: String, _ status: StepStatus) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        // 已经判定失败 / 成功的步骤不因为后续观察到的旧状态而回退。
        if steps[index].status == .failure { return }
        if steps[index].status == .success, status != .failure { return }
        steps[index].status = status
    }

    private func setDetail(_ id: String, detail: String) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].detail = detail
    }
}
