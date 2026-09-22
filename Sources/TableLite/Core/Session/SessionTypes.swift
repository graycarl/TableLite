import Foundation

// MARK: - 连接步骤

/// 建立连接的分步进度。
///
/// 依次显示三条进度提示：SSH 隧道 → MySQL 连接 → 读取服务器信息
/// （`specs/01-connections.md` §5、`docs/tech-designs/05-session-management.md` §3）。
/// 库列表在服务器信息之后拉取，不单独作为一条进度提示。
public enum ConnectStep: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case sshTunnel
    case mysql
    case serverInfo

    /// 界面进度提示。
    public var progressText: String {
        switch self {
        case .sshTunnel: return "正在建立 SSH 隧道…"
        case .mysql: return "正在连接 MySQL…"
        case .serverInfo: return "正在读取服务器信息…"
        }
    }

    /// 状态栏 / 错误面板里的步骤名。
    public var displayName: String {
        switch self {
        case .sshTunnel: return "SSH 隧道"
        case .mysql: return "MySQL 连接"
        case .serverInfo: return "服务器信息"
        }
    }
}

// MARK: - 端点

/// 一个 `host:port` 端点。用于错误文案里的跳板机 / 目标库地址（`specs/10-ssh-tunnel.md` §5）。
public struct HostPort: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// `bastion.example.com:22`。
    public var display: String { "\(host):\(port)" }
}

// MARK: - SSH 凭据

/// 建立隧道时上层传入的一次性 SSH 凭据（内存覆盖，不落盘）。
///
/// 密码 / 口令的正常持久化路径是系统钥匙串（`CredentialKind.sshPassword` /
/// `sshPassphrase`）；本类型只用于「表单刚输入、还没保存」或「弹窗刚回填」的当前会话。
public struct SSHSecrets: Sendable, Equatable {
    public var password: String?
    public var passphrase: String?

    public init(password: String? = nil, passphrase: String? = nil) {
        self.password = password
        self.passphrase = passphrase
    }
}

/// 会话向 UI 索要 SSH 凭据的请求（`specs/10-ssh-tunnel.md` §3.2 / §3.3）。
///
/// 私钥有口令、或密码认证没有可用密码时，`ConnectionSession` 用它请求弹窗；
/// UI 弹窗回填口令，勾选「记住」时由 UI 写入钥匙串。**不含任何凭据值**。
public struct SSHSecretRequest: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// SSH 账号密码（`authMethod == .password`）。
        case password
        /// 私钥口令（`authMethod == .privateKey` 且私钥加密）。
        case passphrase
    }

    public let kind: Kind
    public let connectionID: UUID
    public let connectionName: String
    public let host: String
    public let port: Int
    /// 需要口令的私钥路径（仅 `.passphrase`）。
    public let privateKeyPath: String?

    public init(
        kind: Kind,
        connectionID: UUID,
        connectionName: String,
        host: String,
        port: Int,
        privateKeyPath: String? = nil
    ) {
        self.kind = kind
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.host = host
        self.port = port
        self.privateKeyPath = privateKeyPath
    }
}

// MARK: - 连接失败

/// 连接失败的统一类型。`step` 区分「失败发生在哪一步」。
///
/// SSH 与 MySQL 的错误**分开保存**，UI 不能把两者都说成「连接失败」
/// （`docs/tech-designs/05-session-management.md` §3、`specs/01-connections.md` §4）。
public struct ConnectFailure: Error, Sendable, Equatable {

    public enum Reason: Sendable, Equatable {
        case ssh(SSHTunnelError)
        case mysql(MySQLError)
        case unknown(String)
    }

    public let step: ConnectStep
    public let reason: Reason
    /// SSH 步骤失败时的跳板机端点，用于拼 `无法连接到 SSH 主机 …:22（…）`（`specs/10` §5）。
    public let sshEndpoint: HostPort?
    /// 隧道已建立、但 MySQL 不可达时的目标库端点，用于拼
    /// `SSH 隧道建立成功，但无法从跳板机访问 10.0.2.5:3306`（`specs/10` §5）。
    public let tunneledMySQL: HostPort?

    public init(
        step: ConnectStep,
        reason: Reason,
        sshEndpoint: HostPort? = nil,
        tunneledMySQL: HostPort? = nil
    ) {
        self.step = step
        self.reason = reason
        self.sshEndpoint = sshEndpoint
        self.tunneledMySQL = tunneledMySQL
    }

    /// 失败步骤的标题。
    ///
    /// 隧道启动失败与运行中断开要分开（`specs/10-ssh-tunnel.md` §4）：
    /// 运行中断开时状态栏显示 `SSH 隧道已断开`。
    public var title: String {
        switch step {
        case .sshTunnel:
            if case .ssh(.tunnelClosed) = reason { return "SSH 隧道已断开" }
            return "SSH 隧道建立失败"
        case .mysql: return "MySQL 连接失败"
        case .serverInfo: return "读取服务器信息失败"
        }
    }

    /// 原样保留的底层错误文本（`specs/01-connections.md` §3 要求原样展示）。
    public var underlyingMessage: String {
        switch reason {
        case .ssh(let error):
            return error.stderrTail.isEmpty ? error.displayMessage : error.stderrTail
        case .mysql(let error):
            // 错误码 + SQLSTATE + 服务器原文（`specs/12-feedback.md` §5 规则 2）。
            let state = error.sqlState.isEmpty ? "-" : error.sqlState
            return "[错误 \(error.code)] SQLSTATE \(state) · \(error.message)"
        case .unknown(let text):
            return text
        }
    }

    /// 中文解释行。
    public var explanation: String {
        switch reason {
        case .ssh(let error):
            return error.message(sshHost: sshEndpoint?.host, sshPort: sshEndpoint?.port)
        case .mysql(let error):
            if let tunneledMySQL, error.kind == .connectionFailed {
                return "SSH 隧道建立成功，但无法从跳板机访问 \(tunneledMySQL.display)"
            }
            return error.chineseExplanation
        case .unknown:
            return "发生未知错误。"
        }
    }

    /// 建议的排查方向（`specs/12-feedback.md`）。
    public var suggestion: String? {
        switch reason {
        case .ssh(let error):
            switch error {
            case .authenticationFailed, .privateKeyRejected:
                return "请检查 SSH 用户、密钥或密码。"
            case .hostKeyChanged:
                return "确认服务器是否被重装；核对无误后清理 known_hosts 里的旧记录再连。"
            case .connectionFailed, .startupTimedOut:
                return "检查 SSH 主机、端口、网络与防火墙。"
            case .sshExecutableMissing:
                return "确认系统存在 /usr/bin/ssh。"
            default:
                return nil
            }
        case .mysql(let error):
            switch error.kind {
            case .connectionFailed:
                return "若启用了 SSH，确认目标库从跳板机侧可达。"
            default:
                return nil
            }
        case .unknown:
            return nil
        }
    }

    public var mysqlError: MySQLError? {
        if case .mysql(let error) = reason { return error }
        return nil
    }

    public var sshError: SSHTunnelError? {
        if case .ssh(let error) = reason { return error }
        return nil
    }

    /// 是否是连接已失效类错误（`2006` / `2013`）。
    public var isConnectionLost: Bool {
        mysqlError?.isConnectionLost ?? false
    }
}

// MARK: - 会话连接状态

/// 一个 `ConnectionSession` 的状态机。
///
/// 断开 / 连接中（分步）/ 已连接 / 已回收 / 失败（`specs/01-connections.md` §4）。
public enum SessionConnectionState: Sendable, Equatable {
    /// 未连接。
    case disconnected
    /// 正在连接，携带当前步骤。
    case connecting(ConnectStep)
    /// 已连接。
    case connected
    /// 被空闲回收：已断开，但会话对象与标签保留，界面显示「重新连接」。
    case recycled
    /// 连接失败或运行中失效。
    case failed(ConnectFailure)

    /// 是否占用一条服务器连接（连接上限判断用）。
    public var holdsResources: Bool {
        switch self {
        case .connecting, .connected, .failed:
            return true
        case .disconnected, .recycled:
            return false
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// 状态点对应的中文文案。
    public var displayText: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting(let step): return step.progressText
        case .connected: return "已连接"
        case .recycled: return "已回收"
        case .failed(let failure): return failure.title
        }
    }

    public var failure: ConnectFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    public var step: ConnectStep? {
        if case .connecting(let step) = self { return step }
        return nil
    }
}

// MARK: - 隧道协议

/// `SSHTunnel` 的最小协议面，供 `ConnectionSession` 依赖与单测注入。
public protocol SSHTunnelProtocol: Sendable {
    func start() async throws -> SSHTunnelEndpoint
    func stop() async
    /// 退出清理用的同步等待版本（`05-session-management.md` §7）。
    nonisolated func stopAndWait(timeout: Duration)
    func healthCheck() async -> Bool
    var state: SSHTunnelState { get async }
    var configuration: SSHTunnelConfiguration { get }
}

extension SSHTunnel: SSHTunnelProtocol {}

// MARK: - 后端工厂

/// 构建底层资源（`MySQLSession` / `SSHTunnel`）的工厂。
///
/// 单测注入假实现；真实实现见 `.live`。
public struct SessionBackendFactory: Sendable {
    public var makeMySQLSession: @Sendable () -> any MySQLSessionProtocol
    public var makeTunnel: @Sendable (SSHTunnelConfiguration) -> any SSHTunnelProtocol

    public init(
        makeMySQLSession: @escaping @Sendable () -> any MySQLSessionProtocol,
        makeTunnel: @escaping @Sendable (SSHTunnelConfiguration) -> any SSHTunnelProtocol
    ) {
        self.makeMySQLSession = makeMySQLSession
        self.makeTunnel = makeTunnel
    }

    public static var live: SessionBackendFactory {
        SessionBackendFactory(
            makeMySQLSession: { MySQLSession() },
            makeTunnel: { configuration in SSHTunnel(configuration: configuration) }
        )
    }
}

// MARK: - 服务集合

/// 会话层依赖的仓库与偏好。由 `AppEnvironment` 组装后传入。
@MainActor
public struct SessionServices {
    public let preferences: Preferences
    public let consoleLog: ConsoleLogStore
    public let history: QueryHistoryStore
    public let drafts: QueryDraftStore
    public let sessionState: SessionStateStore
    public let workspace: WorkspaceStateStore
    public let credentials: CredentialStore
    public let clock: Clock
    public let factory: SessionBackendFactory

    public init(
        preferences: Preferences,
        consoleLog: ConsoleLogStore,
        history: QueryHistoryStore,
        drafts: QueryDraftStore,
        sessionState: SessionStateStore,
        workspace: WorkspaceStateStore,
        credentials: CredentialStore,
        clock: Clock,
        factory: SessionBackendFactory
    ) {
        self.preferences = preferences
        self.consoleLog = consoleLog
        self.history = history
        self.drafts = drafts
        self.sessionState = sessionState
        self.workspace = workspace
        self.credentials = credentials
        self.clock = clock
        self.factory = factory
    }
}

// MARK: - 会话管理错误

public enum SessionManagerError: Error, LocalizedError, Equatable {
    /// 超过同时保持的连接上限（`specs/01-connections.md` §6）。
    case connectionLimitReached(limit: Int)
    case sessionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .connectionLimitReached:
            return "同时保持的连接已达上限，请先断开一个不用的连接。"
        case .sessionNotFound:
            return "找不到对应的连接。"
        }
    }
}

// MARK: - 测试连接结果

/// 测试连接逐步结果（`specs/01-connections.md` §3）。
public struct ConnectionTestStep: Sendable, Equatable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        case pending
        case success
        case skipped
        case failure(ConnectFailure)
    }

    public let step: ConnectStep
    public var outcome: Outcome

    public var id: String { step.rawValue }

    public init(step: ConnectStep, outcome: Outcome = .pending) {
        self.step = step
        self.outcome = outcome
    }

    public var isSuccess: Bool { outcome == .success }
    public var failure: ConnectFailure? {
        if case .failure(let failure) = outcome { return failure }
        return nil
    }
}

/// 一次「测试连接」的完整结果。
public struct ConnectionTestReport: Sendable, Equatable {
    public var steps: [ConnectionTestStep]
    public var serverInfo: ServerInfo?
    /// 配置里的库不存在时的提示（不算失败）。
    public var unresolvedDatabase: String?
    /// 隧道建立成功后的本地转发端口（`specs/01-connections.md` §3）。
    public var tunnelLocalPort: UInt16?
    /// 失败步骤（成功时为 nil）。
    public var failure: ConnectFailure?

    public var succeeded: Bool { failure == nil }

    public init(
        steps: [ConnectionTestStep],
        serverInfo: ServerInfo? = nil,
        unresolvedDatabase: String? = nil,
        tunnelLocalPort: UInt16? = nil,
        failure: ConnectFailure? = nil
    ) {
        self.steps = steps
        self.serverInfo = serverInfo
        self.unresolvedDatabase = unresolvedDatabase
        self.tunnelLocalPort = tunnelLocalPort
        self.failure = failure
    }

    /// 由失败步骤构造：之前的步骤算成功，失败及之后算 skipped。
    public static func failed(_ failure: ConnectFailure, sshEnabled: Bool) -> ConnectionTestReport {
        var steps: [ConnectionTestStep] = []
        var reachedFailure = false
        for step in ConnectStep.allCases {
            if step == .sshTunnel, !sshEnabled {
                steps.append(ConnectionTestStep(step: step, outcome: .skipped))
                continue
            }
            if reachedFailure {
                steps.append(ConnectionTestStep(step: step, outcome: .skipped))
            } else if step == failure.step {
                steps.append(ConnectionTestStep(step: step, outcome: .failure(failure)))
                reachedFailure = true
            } else {
                steps.append(ConnectionTestStep(step: step, outcome: .success))
            }
        }
        return ConnectionTestReport(steps: steps, failure: failure)
    }

    /// 全部步骤成功。
    public static func success(
        serverInfo: ServerInfo?,
        unresolvedDatabase: String?,
        sshEnabled: Bool,
        tunnelLocalPort: UInt16? = nil
    ) -> ConnectionTestReport {
        let steps = ConnectStep.allCases
            .filter { $0 != .sshTunnel || sshEnabled }
            .map { ConnectionTestStep(step: $0, outcome: .success) }
        return ConnectionTestReport(
            steps: steps,
            serverInfo: serverInfo,
            unresolvedDatabase: unresolvedDatabase,
            tunnelLocalPort: tunnelLocalPort
        )
    }
}
