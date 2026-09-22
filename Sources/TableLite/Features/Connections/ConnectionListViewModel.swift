import AppKit
import Foundation
import Observation

/// 连接管理界面的状态与编排（`specs/01-connections.md` §1–§5）。
///
/// 只做两件事：把 `ConnectionStore` / `SessionManager` 的状态读出来给界面用，
/// 以及把界面的意图（新建 / 测试 / 连接 / 删除 / 重连）翻译成 Core 层的调用。
/// 所有状态在 `@MainActor` 上；不直接持有 `MySQLSession`。
///
/// `import AppKit` 只用于「在 Finder 中显示配置文件」的 `NSWorkspace`，
/// 这是 AppKit 之外没有等价能力的系统调用（见交付报告）。
@MainActor
@Observable
final class ConnectionListViewModel {

    // MARK: - 行状态

    /// 连接列表一行显示的状态。
    enum RowStatus: Equatable {
        /// 保存着但当前没有会话。
        case notConnected
        /// 正在连接，携带当前步骤。
        case connecting(ConnectStep)
        /// 已连接。
        case connected
        /// 有会话但没连上（恢复出来的骨架 / 被空闲回收 / 连接失败后已断开）：显示「点击重连」。
        case needsReconnect
        /// 连接失败或运行中失效。
        case failed(ConnectFailure)
    }

    // MARK: - 列表与加载

    private(set) var connections: [Connection] = []
    private(set) var notices: [String] = []
    private(set) var isLoading = false
    var searchText: String = ""
    var errorMessage: String?
    var selectedConnectionID: UUID?

    // MARK: - 弹层

    /// 新建 / 编辑表单。
    var isFormPresented = false
    var formState = ConnectionFormState()

    /// 删除确认（`specs/01-connections.md` §1「删除连接」）。
    var pendingDeletion: Connection?

    /// 首次连接但没有保存密码时的输入框（`specs/01-connections.md` §2「密码处理」）。
    var passwordPrompt: PasswordPrompt?

    /// 连接失败详情（列表里点「查看详情」或连接失败时弹出）。
    var failurePresentation: FailurePresentation?

    // MARK: - 测试连接

    var isTestPresented = false
    private(set) var isTesting = false
    private(set) var testReport: ConnectionTestReport?

    // MARK: - 依赖

    private let environment: AppEnvironment
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var manager: SessionManager { environment.sessionManager }

    // MARK: - 派生状态

    /// 搜索框过滤后的连接（按名称与摘要模糊匹配，见 `specs/01-connections.md` §1）。
    var filteredConnections: [Connection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return connections }
        return connections.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    /// 是否存在「恢复出来但未连接」的会话（显示「恢复全部」）。
    var hasReconnectableSessions: Bool {
        manager.sessions.contains { !$0.state.isConnected }
    }

    func status(for connection: Connection) -> RowStatus {
        guard let session = manager.session(id: connection.id) else { return .notConnected }
        switch session.state {
        case .disconnected, .recycled:
            return .needsReconnect
        case .connecting(let step):
            return .connecting(step)
        case .connected:
            return .connected
        case .failed(let failure):
            return .failed(failure)
        }
    }

    // MARK: - 加载

    /// 读取连接列表与需要提示给用户的说明（例如连接文件里混入了密码字段）。
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await environment.connections.load()
            connections = result.connections
            notices = result.notices
        } catch {
            errorMessage = Self.describe(error, fallback: "读取连接列表失败。")
        }
    }

    /// 用户确认看到提示后清除；同时消费 Store 里保留的 notices，避免下次又冒出来。
    func dismissNotices() async {
        notices = []
        _ = await environment.connections.takeNotices()
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 表单

    func beginCreate() {
        resetTestState()
        formState = ConnectionFormState()
        isFormPresented = true
    }

    func beginEdit(_ connection: Connection) async {
        resetTestState()
        var state = ConnectionFormState(connection: connection)
        let stored = (try? environment.credentials.password(for: connection.id, kind: .mysqlPassword)) ?? nil
        state.hasStoredPassword = stored != nil
        state.password = stored ?? ""
        formState = state
        isFormPresented = true
    }

    func cancelForm() {
        isFormPresented = false
        resetTestState()
    }

    /// 保存表单。返回落库后的连接与「本次运行内要用的密码」（没输入时为 nil）。
    @discardableResult
    func saveCurrentForm() async -> FormSaveOutcome? {
        guard isFormPresented else { return nil }
        let update = formState.passwordUpdate
        let connection = formState.makeConnection(now: environment.clock.now)

        // 界面已用同一套校验禁用保存；这里再挡一次，避免竞态写入非法数据。
        guard connection.validationIssues().isEmpty else { return nil }

        do {
            try await environment.connections.upsert(connection)
        } catch {
            errorMessage = Self.describe(error, fallback: "保存连接失败。")
            return nil
        }

        apply(update, connectionID: connection.id)

        isFormPresented = false
        resetTestState()
        await load()
        selectedConnectionID = connection.id
        return FormSaveOutcome(connection: connection, sessionPassword: sessionPassword(for: update))
    }

    /// 「测试连接」面板上的「保存并连接」。
    func saveAndConnectCurrentForm() async {
        guard let outcome = await saveCurrentForm() else { return }
        await connect(outcome.connection, password: outcome.sessionPassword)
    }

    // MARK: - 增删改

    /// 复制为新连接（`specs/01-connections.md` §1 右键菜单）。连同钥匙串凭据一起复制。
    func duplicate(_ connection: Connection) async {
        let copy = connection.duplicated(now: environment.clock.now)
        do {
            try await environment.connections.upsert(copy)
        } catch {
            errorMessage = Self.describe(error, fallback: "复制连接失败。")
            return
        }
        copyCredentials(from: connection.id, to: copy.id)
        await load()
        selectedConnectionID = copy.id
    }

    /// 删除连接（先经 `pendingDeletion` 弹确认），钥匙串由 `ConnectionStore.delete(id:)` 连带清理。
    func delete(_ connection: Connection) async {
        pendingDeletion = nil
        do {
            try await environment.connections.delete(id: connection.id)
        } catch {
            errorMessage = Self.describe(error, fallback: "删除连接失败。")
            return
        }
        await manager.removeSession(id: connection.id)
        if selectedConnectionID == connection.id { selectedConnectionID = nil }
        await load()
    }

    /// 「在 Finder 中显示配置文件」（`specs/01-connections.md` §1 右键菜单）。
    func revealConnectionsFile() {
        NSWorkspace.shared.activateFileViewerSelecting([environment.layout.connectionsFile])
    }

    // MARK: - 连接

    /// 连接一个连接配置。
    ///
    /// `password` 为 nil 时从钥匙串取；取不到则弹出密码输入框（不直接连）。
    func connect(_ connection: Connection, password: String? = nil) async {
        var resolved = password
        if resolved == nil {
            resolved = (try? environment.credentials.password(for: connection.id, kind: .mysqlPassword)) ?? nil
        }
        guard let resolved else {
            passwordPrompt = PasswordPrompt(connection: connection)
            return
        }
        await performConnect(connection, password: resolved)
    }

    /// 密码输入框提交。
    func submitPasswordPrompt(password: String, remember: Bool) async {
        guard let prompt = passwordPrompt else { return }
        passwordPrompt = nil
        if remember, !password.isEmpty {
            try? environment.credentials.setPassword(password, for: prompt.connection.id, kind: .mysqlPassword)
        }
        await performConnect(prompt.connection, password: password)
    }

    func cancelPasswordPrompt() {
        passwordPrompt = nil
    }

    func reconnect(_ connection: Connection) async {
        do {
            try await manager.reconnect(id: connection.id)
        } catch {
            presentConnectFailure(error, connection: connection)
        }
    }

    /// 「恢复全部」：把所有未连接的会话逐个重连；失败不打断后续。
    func reconnectAll() async {
        await manager.reconnectAll()
    }

    private func performConnect(_ connection: Connection, password: String?) async {
        do {
            try await manager.connect(connection, password: password)
        } catch {
            presentConnectFailure(error, connection: connection)
        }
    }

    private func presentConnectFailure(_ error: Error, connection: Connection) {
        if let failure = error as? ConnectFailure {
            failurePresentation = FailurePresentation(failure: failure, connection: connection)
        } else {
            errorMessage = Self.describe(error, fallback: "连接失败。")
        }
    }

    // MARK: - 测试连接

    /// 用表单当前配置发起一次探测；结果按步骤展示（`specs/01-connections.md` §3）。
    func testCurrentForm() {
        testTask?.cancel()
        testTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCurrentFormTest()
        }
    }

    /// 可直接 `await` 的版本；单测与需要顺序控制的调用方用它。
    func runCurrentFormTest() async {
        guard isFormPresented else { return }
        let connection = formState.makeConnection(now: environment.clock.now)
        let password = formState.connectionPassword

        isTestPresented = true
        isTesting = true
        testReport = nil

        let report = await manager.testConnection(connection, password: password)
        guard !Task.isCancelled else {
            isTesting = false
            return
        }
        testReport = report
        isTesting = false
    }

    /// 测试过程可以取消（`specs/01-connections.md` §3）。Core 的探测没有中断点，
    /// 取消只丢弃结果并关掉面板；Core 仍会在结束后立即关掉测试用的连接。
    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        isTestPresented = false
        isTesting = false
        testReport = nil
    }

    private func resetTestState() {
        testTask?.cancel()
        testTask = nil
        isTestPresented = false
        isTesting = false
        testReport = nil
    }

    // MARK: - 私有

    /// `saveCurrentForm` 的结果：落库的连接 + 本次运行内要用的密码。
    struct FormSaveOutcome {
        let connection: Connection
        let sessionPassword: String?
    }

    /// 密码输入框的展示模型。
    struct PasswordPrompt: Identifiable, Equatable {
        let connection: Connection
        var id: UUID { connection.id }
    }

    /// 失败详情弹层。
    struct FailurePresentation: Identifiable {
        let id = UUID()
        let failure: ConnectFailure
        let connection: Connection?
    }

    private func sessionPassword(for update: ConnectionFormState.PasswordUpdate) -> String? {
        switch update {
        case .clear:
            return nil
        case .set(let value), .sessionOnly(let value):
            return value
        }
    }

    private func apply(_ update: ConnectionFormState.PasswordUpdate, connectionID: UUID) {
        do {
            switch update {
            case .set(let password):
                try environment.credentials.setPassword(password, for: connectionID, kind: .mysqlPassword)
            case .sessionOnly, .clear:
                try environment.credentials.deletePassword(for: connectionID, kind: .mysqlPassword)
            }
        } catch {
            errorMessage = Self.describe(error, fallback: "保存密码到钥匙串失败。")
        }
    }

    private func copyCredentials(from source: UUID, to destination: UUID) {
        for kind in CredentialKind.allCases {
            guard let secret = (try? environment.credentials.password(for: source, kind: kind)) ?? nil else {
                continue
            }
            try? environment.credentials.setPassword(secret, for: destination, kind: kind)
        }
    }

    private static func describe(_ error: Error, fallback: String) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return "\(fallback)（\(error)）"
    }
}
