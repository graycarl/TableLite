import Combine
import Foundation
import os

// MARK: - 连接状态

/// 一个连接的界面状态。见 `specs/01-connections.md` §4、
/// `docs/tech-designs/05-session-management.md` §6。
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(ConnectStep)
    case connected
    case failed(MySQLError)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - ConnectionSession

/// 一个数据库连接的全部运行时状态：连接状态、服务器信息、库 / 对象树、标签集合。
///
/// 设计见 `docs/tech-designs/05-session-management.md`：
/// - 每个 session 一个 `MySQLSession` / `MetaRepository`（缓存不跨连接共享）；
/// - 状态与所有 `@Published` 写入都在 `@MainActor`；
/// - 连接失效只置失败、不自动重连（L7，见 `13-open-questions.md`）。
@MainActor
final class ConnectionSession: ObservableObject, Identifiable {

    // MARK: 身份与依赖

    let connection: Connection
    nonisolated var id: UUID { connection.id }

    private let credentials: CredentialStore
    private let preferences: PreferencesStore
    private let consoleLog: ConsoleLogStore
    private let drafts: DraftStore?
    private let clock: Clock
    private let fileSystem: FileSystemLocator

    /// 当前 MySQL 密码。`SessionManager` 在连接 / 重连前注入（Keychain 取回或用户输入）。
    private var mysqlPassword: String?

    // MARK: 状态

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var serverInfo: ServerInfo?

    /// 客户端过滤系统库之后的库列表（界面展示用）。
    @Published private(set) var databases: [String] = []
    /// `SHOW DATABASES` 的原始结果，系统库也在里面（备用）。
    @Published private(set) var unfilteredDatabases: [String] = []
    @Published var selectedDatabase: String?

    @Published private(set) var objects: [DatabaseObject] = []
    @Published private(set) var isLoadingObjects = false
    @Published var objectSearch = ""

    @Published private(set) var tabs: [Tab] = []
    @Published var activeTabID: UUID?

    /// 连接成功但配置里的库不存在时的提示（1049 不算连接失败）。
    @Published private(set) var warning: String?
    @Published private(set) var isReadOnly: Bool

    // MARK: 数据访问层

    private(set) var mysql: MySQLSession
    private(set) var meta: MetaRepository
    private(set) var loader: TableDataLoader
    private(set) var tunnel: SSHTunnel?

    /// 最近一次用户活动时间（空闲回收判断）。
    private(set) var lastActivityAt: Date

    /// 下一个查询标签编号。
    private var nextQueryNumber = 0

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "session")

    // MARK: 初始化

    init(connection: Connection,
         password: String?,
         credentials: CredentialStore,
         preferences: PreferencesStore,
         consoleLog: ConsoleLogStore,
         drafts: DraftStore?,
         clock: Clock,
         fileSystem: FileSystemLocator) {
        self.connection = connection
        self.mysqlPassword = password
        self.credentials = credentials
        self.preferences = preferences
        self.consoleLog = consoleLog
        self.drafts = drafts
        self.clock = clock
        self.fileSystem = fileSystem
        self.isReadOnly = connection.readOnly

        // 先建一份占位数据访问层；真正连接时在 `open()` 里按实际端点（含隧道端口）重建。
        let session = MySQLSession(
            configuration: Self.configuration(for: connection,
                                              host: connection.mysql.host,
                                              port: connection.mysql.port,
                                              database: connection.mysql.database,
                                              password: password),
            clock: clock
        )
        let repository = MetaRepository(session: session, clock: clock)
        self.mysql = session
        self.meta = repository
        self.loader = TableDataLoader(session: session, meta: repository)
        self.lastActivityAt = clock.now
    }

    // MARK: 状态栏数据

    /// 状态栏连接区需要的数据：名称 / 当前库 / 版本 / 字符集 / 只读。
    /// 见 `specs/02-workspace.md` §7、`docs/tech-designs/05-session-management.md` §10。
    var displayName: String { connection.name }
    var serverVersion: String? { serverInfo?.version }
    var charset: String? { serverInfo?.charset }

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }

    var tabsWithPendingChanges: [Tab] { tabs.filter(\.hasPendingChanges) }

    func isIdle(threshold: TimeInterval) -> Bool {
        clock.now.timeIntervalSince(lastActivityAt) > threshold
    }

    func noteActivity() {
        lastActivityAt = clock.now
    }

    func updatePassword(_ password: String?) {
        mysqlPassword = password
    }

    func setReadOnly(_ value: Bool) {
        isReadOnly = value
        noteActivity()
    }

    // MARK: 生命周期

    /// 建立连接：SSH 隧道（若启用）→ MySQL → 服务器信息 → 库列表 / 对象树。
    ///
    /// 失败时保留已建立的资源（例如已建好的隧道），把状态置为 `.failed` 并抛出。
    /// 见 `docs/tech-designs/05-session-management.md` §3、`docs/tech-designs/04-ssh-tunnel.md` §7。
    func open() async throws {
        guard state != .connected else { return }
        warning = nil

        // 1) SSH 隧道
        var host = connection.mysql.host
        var port = connection.mysql.port
        if connection.ssh.enabled {
            state = .connecting(.sshTunnel)
            let tunnel = SSHTunnel(config: connection.ssh,
                                   remoteHost: connection.mysql.host,
                                   remotePort: connection.mysql.port,
                                   password: sshPassword(),
                                   passphrase: sshPassphrase(),
                                   clock: clock,
                                   fileSystem: fileSystem)
            self.tunnel = tunnel
            do {
                port = try await tunnel.start()
                host = "127.0.0.1"
            } catch {
                let mapped = Self.mappedError(error, step: .sshTunnel)
                state = .failed(mapped)
                appendConsoleError(mapped, sql: "SSH \(connection.ssh.host):\(connection.ssh.port)")
                throw mapped
            }
        } else {
            tunnel = nil
        }

        // 2) MySQL 连接
        state = .connecting(.mysql)
        let session = makeMySQLSession(host: host, port: port, database: connection.mysql.database)
        await install(session)
        do {
            try await session.open()
        } catch {
            let mapped = Self.mappedError(error, step: .mysql)
            if !connection.mysql.database.isEmpty, Self.indicatesUnknownDatabase(mapped) {
                // 1049：库不存在不算连接失败。去掉库名重连，只提示。
                let retrySession = makeMySQLSession(host: host, port: port, database: "")
                await install(retrySession)
                do {
                    try await retrySession.open()
                    warning = "连接配置里的数据库 \(connection.mysql.database) 不存在"
                } catch {
                    let retryMapped = Self.mappedError(error, step: .mysql)
                    state = .failed(retryMapped)
                    appendConsoleError(retryMapped, sql: "\(connection.mysql.user)@\(host):\(port)")
                    throw retryMapped
                }
            } else {
                state = .failed(mapped)
                appendConsoleError(mapped, sql: "\(connection.mysql.user)@\(host):\(port)")
                throw mapped
            }
        }

        // 3) 服务器信息（MySQLSession.open 已读全）+ 库列表 / 对象树
        //
        // `MySQLSession.open()` 把「握手 + 读服务器信息」合成一次调用，无法从外部
        // 观察两段；这里把 `.serverInfo` 作为元数据初始化阶段的进度呈现，保证
        // 用户依次看到 隧道 → MySQL → 服务器信息 三步。
        state = .connecting(.serverInfo)
        serverInfo = await mysql.serverInfo

        do {
            try await loadDatabasesAndSelect()
        } catch {
            let mapped = Self.mappedError(error, step: .serverInfo)
            appendConsoleError(mapped, sql: "SHOW DATABASES")
        }
        await refreshObjects()

        state = .connected
        noteActivity()
        logger.info("已连接 \(self.connection.name, privacy: .public)")
    }

    /// 断开连接：关 MySQL、停隧道。标签保留，状态置为未连接。
    /// 见 `specs/01-connections.md` §5。
    func close() async {
        await mysql.close()
        if let tunnel {
            await tunnel.stop()
        }
        tunnel = nil
        state = .disconnected
        noteActivity()
        logger.info("已断开 \(self.connection.name, privacy: .public)")
    }

    /// 重新连接：重建隧道与 `MySQLSession`、刷新对象树与当前标签数据；
    /// **标签里的暂存改动不清空**（见 `docs/tech-designs/05-session-management.md` §6）。
    func reconnect() async throws {
        await close()
        try await open()
        await reloadTabsAfterReconnect()
    }

    /// 刷新对象树。失败只记 Console Log，不抛给调用方（`refreshObjects()` 是 UI 意图）。
    func refreshObjects() async {
        do {
            try await loadObjects()
        } catch {
            let mapped = Self.mappedError(error, step: .serverInfo)
            appendConsoleError(mapped, sql: "information_schema.TABLES")
        }
        noteActivity()
    }

    /// 重新拉取库列表（例如偏好里切换了「显示系统库」）。失败只记 Console Log。
    func reloadDatabases() async {
        do {
            await meta.invalidateAll()
            try await loadDatabasesAndSelect()
            try await loadObjects()
        } catch {
            let mapped = Self.mappedError(error, step: .serverInfo)
            appendConsoleError(mapped, sql: "SHOW DATABASES")
        }
        noteActivity()
    }

    // MARK: 标签

    @discardableResult
    func openTableData(_ ref: TableRef, forceNew: Bool = false) -> Tab {
        openTab(kind: .tableData(ref), forceNew: forceNew)
    }

    @discardableResult
    func openTableStructure(_ ref: TableRef, forceNew: Bool = false) -> Tab {
        openTab(kind: .tableStructure(ref), forceNew: forceNew)
    }

    @discardableResult
    func openObjectDefinition(_ ref: TableRef, kind: DatabaseObjectKind, forceNew: Bool = false) -> Tab {
        openTab(kind: .objectDefinition(ref, kind), forceNew: forceNew)
    }

    @discardableResult
    func newQueryTab(initialSQL: String = "") -> Tab {
        nextQueryNumber += 1
        let draftID = UUID()
        let tab = Tab(kind: .query(draftID), queryNumber: nextQueryNumber)
        if !initialSQL.isEmpty {
            tab.initialSQL = initialSQL
            if let drafts {
                do {
                    try drafts.save(initialSQL, draftID: draftID)
                } catch {
                    storeLogger.error("查询草稿写入失败：\(String(describing: error), privacy: .public)")
                }
            }
        }
        tabs.append(tab)
        activeTabID = tab.id
        noteActivity()
        return tab
    }

    @discardableResult
    func openHistoryTab() -> Tab {
        openTab(kind: .history, forceNew: false)
    }

    @discardableResult
    func openConsoleLogTab() -> Tab {
        openTab(kind: .consoleLog, forceNew: false)
    }

    func closeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)

        // 关闭查询标签时删除草稿（已另存为磁盘文件的除外，由调用方处理）。
        // 见 docs/tech-designs/05-session-management.md §9。
        if let draftID = tab.kind.draftID, let drafts {
            do {
                try drafts.delete(draftID: draftID)
            } catch {
                storeLogger.error("查询草稿删除失败：\(String(describing: error), privacy: .public)")
            }
        }

        if activeTabID == tab.id {
            if tabs.indices.contains(index) {
                activeTabID = tabs[index].id
            } else {
                activeTabID = tabs.last?.id
            }
        }
        noteActivity()
    }

    func selectTab(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        activeTabID = tab.id
        noteActivity()
    }

    // MARK: 恢复

    /// 按 `session.json` 恢复该会话的标签骨架（不自动连接）。
    func restoreTabs(from snapshots: [SessionStateStore.TabSnapshot], activeIndex: Int?) {
        var restored: [Tab] = []
        for snapshot in snapshots {
            guard let kind = Self.tabKind(from: snapshot) else { continue }
            let tab: Tab
            if case .query = kind {
                nextQueryNumber += 1
                tab = Tab(kind: kind, queryNumber: nextQueryNumber)
            } else {
                // 未连接时结构 / 对象定义视为「可能过期」，连接后刷新。
                let stale: Bool
                switch kind {
                case .tableStructure, .objectDefinition: stale = true
                default: stale = false
                }
                tab = Tab(kind: kind, queryNumber: 0, isStale: stale)
            }
            restored.append(tab)
        }
        tabs = restored
        if let activeIndex, restored.indices.contains(activeIndex) {
            activeTabID = restored[activeIndex].id
        } else {
            activeTabID = restored.first?.id
        }
    }

    // MARK: 私有 — 数据访问层装配

    private func makeMySQLSession(host: String, port: Int, database: String) -> MySQLSession {
        MySQLSession(
            configuration: Self.configuration(for: connection,
                                              host: host,
                                              port: port,
                                              database: database,
                                              password: mysqlPassword),
            clock: clock
        )
    }

    private func install(_ session: MySQLSession) async {
        mysql = session
        let repository = MetaRepository(session: session, clock: clock)
        meta = repository
        loader = TableDataLoader(session: session, meta: repository)

        await session.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }
    }

    private func handle(event: MySQLSessionEvent) {
        switch event {
        case .connectionLost(let serverError):
            // 不自动重连（L7）：只标记失败，由用户手动「重新连接」。
            let error = MySQLError.connectionLost(serverError)
            state = .failed(error)
            appendConsoleError(error, sql: "连接心跳失败")
        }
    }

    private func reloadTabsAfterReconnect() async {
        for tab in tabs {
            if let reload = tab.reloadAfterReconnect {
                await reload()
            }
        }
    }

    // MARK: 私有 — 元数据

    private func loadDatabasesAndSelect() async throws {
        let accessible = try await meta.databases(includeSystem: true)
        unfilteredDatabases = accessible
        databases = try await meta.databases(includeSystem: preferences.showSystemDatabases)

        let configured = connection.mysql.database
        if !configured.isEmpty, accessible.contains(configured) {
            selectedDatabase = configured
        } else if let current = selectedDatabase, accessible.contains(current) {
            // 保持上次选择
        } else {
            selectedDatabase = databases.first ?? accessible.first
            if !configured.isEmpty, !accessible.contains(configured) {
                warning = "连接配置里的数据库 \(configured) 不存在"
            }
        }
    }

    private func loadObjects() async throws {
        guard let database = selectedDatabase else {
            objects = []
            return
        }
        isLoadingObjects = true
        defer { isLoadingObjects = false }
        objects = try await meta.objects(database: database)
    }

    // MARK: 私有 — SSH 凭据

    private func sshPassword() -> String? {
        guard connection.ssh.enabled, connection.ssh.authMethod == .password else { return nil }
        return try? credentials.retrieve(CredentialKey(kind: .sshPassword, connectionID: connection.id))
    }

    private func sshPassphrase() -> String? {
        guard connection.ssh.enabled, connection.ssh.authMethod == .privateKey else { return nil }
        return try? credentials.retrieve(CredentialKey(kind: .sshPassphrase, connectionID: connection.id))
    }

    // MARK: 私有 — 标签

    private func openTab(kind: TabKind, forceNew: Bool) -> Tab {
        if !forceNew, let index = TabKind.existingTab(for: kind, in: tabs.map(\.kind)) {
            activeTabID = tabs[index].id
            noteActivity()
            return tabs[index]
        }

        let tab: Tab
        if case .query = kind {
            nextQueryNumber += 1
            tab = Tab(kind: kind, queryNumber: nextQueryNumber)
        } else {
            tab = Tab(kind: kind)
        }
        tabs.append(tab)
        activeTabID = tab.id
        noteActivity()
        return tab
    }

    // MARK: 私有 — Console Log

    private func appendConsoleError(_ error: MySQLError, sql: String) {
        consoleLog.append(.init(timestamp: clock.now,
                                category: .meta,
                                database: selectedDatabase,
                                sql: sql,
                                errorCode: error.serverError?.code,
                                errorMessage: error.title))
    }

    // MARK: 私有 — 工具

    private static func configuration(for connection: Connection,
                                      host: String,
                                      port: Int,
                                      database: String,
                                      password: String?) -> MySQLSession.Configuration {
        var mysql = connection.mysql
        mysql.database = database
        return MySQLSession.Configuration(mysql: mysql, password: password, host: host, port: port)
    }

    private static func mappedError(_ error: Error, step: ConnectStep) -> MySQLError {
        if let mysqlError = error as? MySQLError { return mysqlError }
        return MySQLErrorMapper.connectFailure(step: step,
                                               message: "\(step.displayName)失败",
                                               detail: String(describing: error))
    }

    /// 连接握手返回的 `1049` 被 C 层统一映射成 `.connect(step: .mysql, message:)`，
    /// 丢失了错误码，只能从消息文本判断「库不存在」。见 `Core/MySQL/CMySQLBridge.swift`。
    private static func indicatesUnknownDatabase(_ error: MySQLError) -> Bool {
        guard case .connect(let step, let message, let detail) = error, step == .mysql else {
            return false
        }
        let text = (message + " " + (detail ?? "")).lowercased()
        return text.contains("unknown database") || text.contains("1049")
    }

    // MARK: 私有 — 恢复辅助

    private static func tabKind(from snapshot: SessionStateStore.TabSnapshot) -> TabKind? {
        switch snapshot.kind {
        case "tableData":
            guard let database = snapshot.database, let name = snapshot.objectName else { return nil }
            return .tableData(TableRef(database: database, table: name))
        case "tableStructure":
            guard let database = snapshot.database, let name = snapshot.objectName else { return nil }
            return .tableStructure(TableRef(database: database, table: name))
        case "objectDefinition":
            guard let database = snapshot.database, let name = snapshot.objectName else { return nil }
            // TabSnapshot 没有存 DatabaseObjectKind，恢复时按视图处理（定义语句只读）。
            return .objectDefinition(TableRef(database: database, table: name), .view)
        case "query":
            guard let draftID = snapshot.draftID else { return nil }
            return .query(draftID)
        default:
            return nil
        }
    }
}
