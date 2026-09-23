import Foundation
import Observation

/// 一个连接的会话：聚合连接配置、状态、MySQL 会话、可选隧道、元数据仓库与标签列表。
///
/// 设计见 `docs/tech-designs/05-session-management.md` §2：
/// - 视图不直接持有 `MySQLSession`；所有数据库访问经过本类型 / `MetaRepository`；
/// - 每个会话一个 `MetaRepository`，缓存不跨连接共享；
/// - 连接流程分步推进（SSH → MySQL → 服务器信息 → 库列表）。
///
/// `@MainActor` + `@Observable`：UI 直接绑定（`06-ui-layer.md` §2）。
@MainActor
@Observable
public final class ConnectionSession: Identifiable {

    // MARK: 身份

    public let id: UUID
    public private(set) var connection: Connection
    /// 只读标记（`specs/09-readonly-mode.md`）。
    public var isReadOnly: Bool

    // MARK: 数据访问层

    /// 底层 MySQL 会话。UI 不得直接访问：经本类型或 `MetaRepository`。
    @ObservationIgnored public let mysql: any MySQLSessionProtocol
    /// 元数据仓库（每个会话一个，缓存不跨连接共享）。
    @ObservationIgnored public let meta: MetaRepository
    @ObservationIgnored private let services: SessionServices

    /// 当前 SSH 隧道（未启用 SSH 时为 nil）。
    public private(set) var tunnel: (any SSHTunnelProtocol)?
    /// 隧道建立后的本地转发端点；未启用 / 未建立时为 nil。
    ///
    /// 测试面板与状态栏悬停详情用它显示 `本地转发端口 127.0.0.1:<port>`
    /// （`specs/10-ssh-tunnel.md` §4、`specs/01-connections.md` §3）。
    public private(set) var tunnelEndpoint: SSHTunnelEndpoint?

    // MARK: 状态

    public private(set) var state: SessionConnectionState = .disconnected
    /// 配置里的库不存在时的提示（不算连接失败）。
    public private(set) var warning: String?
    /// 配置里的库名（`1049`）不存在时记录；连接本身成功。
    public private(set) var unresolvedDatabase: String?
    /// 切库时服务器拒绝 `USE`（库被删 / 无权限）的轻提示，约 4 秒后自动消失。
    public private(set) var databaseSwitchNotice: String?
    /// 最近一次活动时间（空闲回收用）。
    public private(set) var lastActivity: Date

    // MARK: 库 / 对象

    public private(set) var databases: [String] = []
    public private(set) var unfilteredDatabases: [String] = []
    public var selectedDatabase: String?
    public private(set) var objects: [TableInfo] = []
    public private(set) var isLoadingObjects = false
    public private(set) var serverInfo: ServerInfo?

    // MARK: 标签

    public var tabs: [Tab] = []
    public var activeTabID: UUID?
    @ObservationIgnored private var nextQueryNumber = 0

    // MARK: 凭据（内存覆盖，不落盘）

    @ObservationIgnored private var mysqlPassword: String?
    @ObservationIgnored private var sshPassword: String?
    @ObservationIgnored private var sshPassphrase: String?
    /// 测试连接等场景下不写查询历史 / Console Log。
    @ObservationIgnored private let recordsQueries: Bool
    /// 服务器端实际的默认库（最佳估计）：连接建立时取自连接配置，之后随切库更新。
    ///
    /// 用来判断是否需要发 `USE`，以及切库失败时回滚选择。
    /// 见 `docs/tech-designs/05-session-management.md` §11。
    @ObservationIgnored private var syncedDatabase: String?
    /// `databaseSwitchNotice` 的自动清除任务。
    @ObservationIgnored private var databaseNoticeTask: Task<Void, Never>?

    // MARK: 初始化

    public init(
        connection: Connection,
        password: String?,
        services: SessionServices,
        recordsQueries: Bool = true
    ) {
        self.id = connection.id
        self.connection = connection
        self.isReadOnly = connection.isReadOnly
        self.services = services
        self.mysqlPassword = password
        self.recordsQueries = recordsQueries
        self.lastActivity = services.clock.now
        self.nextQueryNumber = 0

        let mysql = services.factory.makeMySQLSession()
        self.mysql = mysql
        let consoleLog = services.consoleLog
        self.meta = MetaRepository(session: mysql, clock: services.clock) { record in
            guard recordsQueries else { return }
            Task { @MainActor in
                await consoleLog.record(
                    tag: record.tag,
                    database: record.database,
                    sql: record.sql,
                    durationMilliseconds: record.durationMilliseconds,
                    returnedRowCount: record.returnedRowCount,
                    affectedRows: record.affectedRows.map { Int($0) },
                    errorCode: record.errorCode,
                    errorMessage: record.errorMessage,
                    isCancelled: record.isCancelled
                )
            }
        }
    }

    // MARK: 连接配置更新

    /// 更新连接配置；返回是否需要重连（主机 / 端口 / SSH 变化）。
    @discardableResult
    public func updateConnection(_ newConnection: Connection) -> Bool {
        let needsReconnect = newConnection.mysql != connection.mysql || newConnection.ssh != connection.ssh
        connection = newConnection
        isReadOnly = newConnection.isReadOnly
        return needsReconnect
    }

    public func updatePassword(_ password: String?) {
        mysqlPassword = password
    }

    public func setSSHSecrets(password: String?, passphrase: String?) {
        if let password { sshPassword = password }
        if let passphrase { sshPassphrase = passphrase }
    }

    /// 需要 SSH 凭据时由 UI 弹窗回填的挂载点；返回 nil 表示用户取消。
    ///
    /// `specs/10-ssh-tunnel.md` §3.2：带口令的私钥首次连接弹输入框；§3.3：
    /// 密码认证在表单里填过密码，个别情况下（未保存）也走同一个弹窗。
    @ObservationIgnored public var sshSecretRequester: (@MainActor (SSHSecretRequest) async -> String?)?

    public func setReadOnly(_ value: Bool) {
        isReadOnly = value
        connection.isReadOnly = value
    }

    // MARK: 连接流程（05 §3）

    /// 建立连接：SSH 隧道（若启用）→ MySQL 连接 → 读取服务器信息 → 库列表。
    ///
    /// 失败时保留已建立的资源，状态置为 `.failed` 并抛出 `ConnectFailure`。
    public func open() async throws {
        if state.isConnected { return }
        warning = nil

        // 1) SSH 隧道
        var host = connection.mysql.host
        var port = connection.mysql.port

        if connection.ssh.enabled {
            state = .connecting(.sshTunnel)
            let secret = await resolveSSHSecret()
            let configuration = SSHTunnelConfiguration.make(connection: connection, secret: secret)
            let tunnel = services.factory.makeTunnel(configuration)
            self.tunnel = tunnel
            do {
                let endpoint = try await tunnel.start()
                tunnelEndpoint = endpoint
                host = endpoint.host
                port = Int(endpoint.port)
            } catch {
                let failure = sshFailure(error)
                state = .failed(failure)
                recordConnectFailure(failure)
                throw failure
            }
        } else {
            tunnel = nil
        }

        // 2) MySQL 连接
        state = .connecting(.mysql)
        var parameters = MySQLConnectionParameters(
            config: connection.mysql,
            password: resolvedMySQLPassword()
        )
        parameters.host = host
        parameters.port = Self.normalizedPort(port)
        do {
            try await mysql.connect(parameters)
        } catch {
            let failure = mysqlFailure(error)
            state = .failed(failure)
            recordConnectFailure(failure)
            throw failure
        }
        // 1049：库不存在不算连接失败（05 §3）。
        if let unresolved = await mysql.unresolvedDatabase, !unresolved.isEmpty {
            unresolvedDatabase = unresolved
            warning = "连接配置里的数据库 \(unresolved) 不存在"
        } else {
            unresolvedDatabase = nil
        }

        // 3) 服务器信息（只查一次，状态栏复用）
        state = .connecting(.serverInfo)
        do {
            serverInfo = try await meta.serverInfo()
        } catch {
            // 读取服务器信息失败不算致命：继续连，只是状态栏缺信息。
            StoreLog.error("读取服务器信息失败：\(error)")
        }

        await loadDatabasesAndSelect()
        // 服务器已用连接配置里的库打开（`1049` 时会退化为不选库），先据此登记。
        let configured = connection.mysql.database
        syncedDatabase = (configured.isEmpty || unresolvedDatabase != nil) ? nil : configured

        state = .connected
        // 让服务器默认库跟随当前选中库：编辑器里不带库名的 SQL 才能落在当前库上。
        await syncSelectedDatabaseOnServer(rollbackOnFailure: false)
        await refreshObjects()

        noteActivity()
        StoreLog.info("已连接 \(connection.name)")
    }

    /// 断开连接。标签保留，状态置为未连接。
    public func close() async {
        await close(reason: .disconnected)
    }

    private enum CloseReason {
        case disconnected
        case recycled
    }

    private func close(reason: CloseReason) async {
        if let tunnel {
            await tunnel.stop()
        }
        tunnel = nil
        tunnelEndpoint = nil
        await mysql.disconnect()
        switch reason {
        case .disconnected: state = .disconnected
        case .recycled: state = .recycled
        }
        noteActivity()
    }

    /// 空闲回收：断开但保留会话对象与标签，界面显示「重新连接」。
    public func recycleResources() async {
        await close(reason: .recycled)
    }

    /// 重新连接：重建隧道与 MySQL 连接、刷新对象树；
    /// **标签里的暂存改动不清空**（05 §6）。
    public func reconnect() async throws {
        await close(reason: .disconnected)
        try await open()
        await reloadTabsAfterReconnect()
    }

    /// 连接成功后重载还原出来的标签内容（`05-session-management.md` §8）。
    ///
    /// 先 `restore(from:)` 装回现场、再 `open()`，然后调本方法把表数据标签重新拉回来。
    public func reloadTabsAfterReconnect() async {
        for tab in tabs {
            if let reload = tab.reloadAfterReconnect {
                await reload()
            }
        }
    }

    // MARK: 保活

    /// 心跳。失败（`2006` / `2013`）时标记失效并抛错（不自动重连，L7）。
    ///
    /// 有 SSH 隧道时先探测隧道是否还在：隧道进程先于 MySQL 断开时，状态里说的是
    /// 「SSH 隧道已断开」而不是笼统的 MySQL 连接失败（`specs/10-ssh-tunnel.md` §4）。
    public func ping() async {
        guard state.isConnected else { return }
        if let tunnel, await tunnel.healthCheck() == false {
            let error = await tunnel.state.error ?? .tunnelClosed(stderrTail: "")
            let failure = ConnectFailure(step: .sshTunnel, reason: .ssh(error))
            state = .failed(failure)
            recordConnectFailure(failure)
            return
        }
        do {
            try await mysql.ping()
        } catch {
            let failure = mysqlFailure(error)
            state = .failed(failure)
            recordConnectFailure(failure)
        }
    }

    // MARK: 库 / 对象

    /// 拉取库列表并按配置选中。
    public func loadDatabasesAndSelect() async {
        do {
            let all = try await meta.allDatabases()
            unfilteredDatabases = all
            databases = MetaMapping.filterSystemDatabases(
                all,
                includeSystem: services.preferences.showSystemDatabases
            )
            let configured = connection.mysql.database
            if !configured.isEmpty, all.contains(configured) {
                selectedDatabase = configured
            } else if let current = selectedDatabase, all.contains(current) {
                // 保持上次选择
            } else {
                selectedDatabase = databases.first ?? all.first
            }
        } catch {
            StoreLog.error("加载数据库列表失败：\(error)")
        }
    }

    /// 刷新对象树。失败只记日志，不抛给调用方。
    public func refreshObjects() async {
        guard let database = selectedDatabase else {
            objects = []
            return
        }
        isLoadingObjects = true
        do {
            objects = try await meta.objects(database: database)
        } catch {
            StoreLog.error("刷新对象树失败：\(error)")
        }
        isLoadingObjects = false
        noteActivity()
    }

    /// 切换当前库：先在服务器上同步（`USE`），失败则回滚选择并提示；成功再刷新对象树。
    ///
    /// 服务器默认库在切库时就同步，编辑器里不带库名的 SQL 才会落到当前库上。
    public func selectDatabase(_ database: String?) async {
        selectedDatabase = database
        await syncSelectedDatabaseOnServer(rollbackOnFailure: true)
        await refreshObjects()
    }

    /// 重新拉取库列表（偏好里切换「显示系统库」等）。
    public func reloadDatabases() async {
        await meta.invalidateDatabases()
        await loadDatabasesAndSelect()
        await syncSelectedDatabaseOnServer(rollbackOnFailure: false)
        await refreshObjects()
    }

    /// 把当前 `selectedDatabase` 同步为服务器的连接默认库（`USE`）。
    ///
    /// 与 `syncedDatabase` 相同就跳过，避免每次切回来都多一次往返。
    /// 失败时（`rollbackOnFailure`）把选择回滚到服务器实际还在的库，并提示，
    /// 以免界面显示已切换、实际还查旧库。
    private func syncSelectedDatabaseOnServer(rollbackOnFailure: Bool) async {
        guard state.isConnected, let database = selectedDatabase, !database.isEmpty else { return }
        guard database != syncedDatabase else { return }
        do {
            try await applyServerDatabase(database)
            syncedDatabase = database
            clearDatabaseSwitchNotice()
        } catch {
            StoreLog.error("切换数据库失败（\(database)）：\(error)")
            guard rollbackOnFailure else { return }
            selectedDatabase = syncedDatabase
            showDatabaseSwitchNotice("无法切换到数据库 \(database)")
        }
    }

    /// 在连接上执行 `USE`。记 Console Log（`[meta]`，客户端自动发出），**不记查询历史**。
    private func applyServerDatabase(_ database: String) async throws {
        let sql = "USE \(SQLIdentifier.quote(database))"
        guard recordsQueries else {
            _ = try await mysql.execute(sql, unbuffered: false)
            return
        }
        let started = services.clock.now
        do {
            _ = try await mysql.execute(sql, unbuffered: false)
            await services.consoleLog.record(
                tag: .meta,
                database: database,
                sql: sql,
                durationMilliseconds: Self.milliseconds(from: started, to: services.clock.now)
            )
        } catch {
            let mysqlError = error as? MySQLError
            await services.consoleLog.record(
                tag: .meta,
                database: database,
                sql: sql,
                durationMilliseconds: Self.milliseconds(from: started, to: services.clock.now),
                errorCode: mysqlError?.code,
                errorMessage: mysqlError?.message ?? String(describing: error),
                isCancelled: mysqlError?.isCancellation ?? false
            )
            throw error
        }
    }

    private func showDatabaseSwitchNotice(_ message: String) {
        databaseSwitchNotice = message
        databaseNoticeTask?.cancel()
        databaseNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.databaseSwitchNotice = nil
        }
    }

    private func clearDatabaseSwitchNotice() {
        databaseNoticeTask?.cancel()
        databaseNoticeTask = nil
        databaseSwitchNotice = nil
    }

    // MARK: 查询入口（统一记录历史与 Console Log）

    /// 执行一段 SQL（用户发起的入口）。
    ///
    /// 统一记录 Console Log 与查询历史；DDL 后失效元数据缓存并刷新对象树。
    /// 见 `06-ui-layer.md` §2、`11-schema-and-import-export.md` §1.2。
    @discardableResult
    public func execute(
        _ sql: String,
        database: String? = nil,
        recordHistory: Bool = true
    ) async throws -> MySQLQueryResult {
        guard recordsQueries else {
            return try await mysql.execute(sql, unbuffered: false)
        }
        let database = database ?? selectedDatabase
        let started = services.clock.now
        do {
            let result = try await mysql.execute(sql, unbuffered: false)
            let duration = Self.milliseconds(from: started, to: services.clock.now)
            await services.consoleLog.record(
                tag: .data,
                database: database,
                sql: sql,
                durationMilliseconds: duration,
                returnedRowCount: result.rowCount,
                affectedRows: Int(result.affectedRows),
                errorCode: result.firstError?.code,
                errorMessage: result.firstError?.message,
                isCancelled: result.wasCancelled
            )
            if recordHistory {
                await appendHistory(
                    sql: sql,
                    database: database,
                    succeeded: !result.hasErrors && !result.wasCancelled,
                    durationMilliseconds: duration,
                    returnedRowCount: result.rowCount,
                    affectedRows: result.affectedRows,
                    error: result.firstError
                )
            }
            await handleExecutedSQL(sql)
            noteActivity()
            return result
        } catch {
            let duration = Self.milliseconds(from: started, to: services.clock.now)
            let mysqlError = error as? MySQLError
            await services.consoleLog.record(
                tag: .data,
                database: database,
                sql: sql,
                durationMilliseconds: duration,
                errorCode: mysqlError?.code,
                errorMessage: mysqlError?.message ?? String(describing: error),
                isCancelled: mysqlError?.isCancellation ?? false
            )
            if recordHistory {
                await appendHistory(
                    sql: sql,
                    database: database,
                    succeeded: false,
                    durationMilliseconds: duration,
                    returnedRowCount: nil,
                    affectedRows: nil,
                    error: mysqlError
                )
            }
            if let mysqlError, mysqlError.isConnectionLost {
                let failure = ConnectFailure(step: .mysql, reason: .mysql(mysqlError))
                state = .failed(failure)
            }
            throw error
        }
    }

    /// 流式执行入口；同样统一记录。
    @discardableResult
    public func streamQuery(
        _ sql: String,
        database: String? = nil,
        unbuffered: Bool = false,
        onEvent: @escaping @Sendable (MySQLQueryEvent) -> Void
    ) async throws -> MySQLQuerySummary {
        guard recordsQueries else {
            return try await mysql.streamQuery(sql, unbuffered: unbuffered, onEvent: onEvent)
        }
        let database = database ?? selectedDatabase
        let started = services.clock.now
        do {
            let summary = try await mysql.streamQuery(sql, unbuffered: unbuffered, onEvent: onEvent)
            let duration = Self.milliseconds(from: started, to: services.clock.now)
            await services.consoleLog.record(
                tag: .data,
                database: database,
                sql: sql,
                durationMilliseconds: duration,
                returnedRowCount: summary.rowCount,
                affectedRows: Int(summary.affectedRows),
                errorCode: summary.firstError?.code,
                errorMessage: summary.firstError?.message,
                isCancelled: summary.wasCancelled
            )
            await appendHistory(
                sql: sql,
                database: database,
                succeeded: !summary.hasErrors && !summary.wasCancelled,
                durationMilliseconds: duration,
                returnedRowCount: summary.rowCount,
                affectedRows: summary.affectedRows,
                error: summary.firstError
            )
            await handleExecutedSQL(sql)
            noteActivity()
            return summary
        } catch {
            let mysqlError = error as? MySQLError
            await services.consoleLog.record(
                tag: .data,
                database: database,
                sql: sql,
                durationMilliseconds: Self.milliseconds(from: started, to: services.clock.now),
                errorCode: mysqlError?.code,
                errorMessage: mysqlError?.message ?? String(describing: error),
                isCancelled: mysqlError?.isCancellation ?? false
            )
            throw error
        }
    }

    /// 取消当前查询。失败时抛错，由上层提示「取消失败，查询仍在服务器上运行」（`03-mysql-layer.md` §5）。
    public func cancelCurrentQuery() async throws {
        try await mysql.cancel()
    }

    private func handleExecutedSQL(_ sql: String) async {
        guard SQLStatementClassifier.containsDDL(sql) else { return }
        let invalidation = await meta.noteExecutedSQL(sql, currentDatabase: selectedDatabase)
        markStaleTabs(invalidation)
        await refreshObjects()
    }

    private func markStaleTabs(_ invalidation: DDLInvalidation) {
        let refs = invalidation.resolvedTables(currentDatabase: selectedDatabase)
        let markAll = invalidation.invalidatesWholeDatabase || refs.isEmpty
        for tab in tabs {
            switch tab.kind {
            case .tableStructure(let database, let table), .objectDefinition(let database, let table):
                if markAll || refs.contains(TableRef(database: database, table: table)) {
                    tab.isStale = true
                }
            default:
                break
            }
        }
    }

    private func appendHistory(
        sql: String,
        database: String?,
        succeeded: Bool,
        durationMilliseconds: Int,
        returnedRowCount: Int?,
        affectedRows: Int64?,
        error: MySQLError?
    ) async {
        let entry = QueryHistoryEntry(
            id: 0,
            connectionID: id,
            database: database,
            sql: sql,
            executedAt: services.clock.now,
            succeeded: succeeded,
            durationMilliseconds: durationMilliseconds,
            returnedRowCount: returnedRowCount,
            affectedRows: affectedRows.map { Int($0) },
            errorCode: error?.code,
            errorMessage: error?.message
        )
        do {
            try await services.history.append(entry)
        } catch {
            StoreLog.error("写入查询历史失败：\(error)")
        }
    }

    // MARK: 标签

    @discardableResult
    public func openTableData(database: String, table: String, forceNew: Bool = false, initialFilter: FilterState? = nil) -> Tab {
        let tab = openTab(kind: .tableData(database: database, table: table), forceNew: forceNew)
        if let initialFilter {
            tab.initialFilter = initialFilter
        }
        return tab
    }

    @discardableResult
    public func openTableStructure(database: String, table: String, forceNew: Bool = false) -> Tab {
        openTab(kind: .tableStructure(database: database, table: table), forceNew: forceNew)
    }

    @discardableResult
    public func openObjectDefinition(database: String, object: String, forceNew: Bool = false) -> Tab {
        openTab(kind: .objectDefinition(database: database, object: object), forceNew: forceNew)
    }

    @discardableResult
    public func openHistoryTab() -> Tab {
        openTab(kind: .history)
    }

    @discardableResult
    public func openConsoleLogTab() -> Tab {
        openTab(kind: .consoleLog)
    }

    /// 打开（或复用）一个标签。
    @discardableResult
    public func openTab(kind: TabKind, forceNew: Bool = false) -> Tab {
        if !forceNew, let index = TabKind.existingIndex(for: kind, in: tabs.map(\.kind)) {
            activeTabID = tabs[index].id
            noteActivity()
            return tabs[index]
        }
        let tab: Tab
        if kind.isQuery {
            nextQueryNumber += 1
            tab = Tab(kind: kind, queryNumber: nextQueryNumber)
        } else {
            tab = Tab(kind: kind)
        }
        // 表数据标签的列布局按「连接 + 库 + 表」从 WorkspaceStateStore 恢复。
        if case .tableData(let database, let table) = kind,
           let layout = tableLayout(database: database, table: table) {
            tab.hiddenColumns = layout.hiddenColumns
        }
        tabs.append(tab)
        activeTabID = tab.id
        noteActivity()
        return tab
    }

    /// 新建查询标签（`⌘T`）。查询标签总是新建。
    @discardableResult
    public func newQueryTab(initialSQL: String = "") -> Tab {
        nextQueryNumber += 1
        let draftID = UUID()
        let tab = Tab(kind: .query(draftID: draftID), queryNumber: nextQueryNumber)
        if !initialSQL.isEmpty {
            tab.initialSQL = initialSQL
            let drafts = services.drafts
            Task { try? await drafts.write(initialSQL, id: draftID) }
        }
        tabs.append(tab)
        activeTabID = tab.id
        noteActivity()
        return tab
    }

    /// 关闭标签。查询标签的草稿随之删除（已另存为磁盘文件的除外）。
    public func closeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if let draftID = tab.kind.draftID, tab.filePath == nil {
            let drafts = services.drafts
            Task { try? await drafts.delete(id: draftID) }
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

    public func selectTab(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        activeTabID = tab.id
        noteActivity()
    }

    // MARK: 表数据列布局（WorkspaceStateStore）

    /// 读取表数据标签的列布局（列宽 / 列显隐）。
    public func tableLayout(database: String, table: String) -> TableLayout? {
        guard services.preferences.rememberColumnLayout else { return nil }
        return services.workspace.layout(connectionID: id, database: database, table: table)
    }

    /// 保存表数据标签的列布局（列宽 / 列显隐）；偏好关闭时忽略。
    public func saveTableLayout(database: String, table: String, layout: TableLayout) {
        guard services.preferences.rememberColumnLayout else { return }
        services.workspace.setLayout(layout, connectionID: id, database: database, table: table)
    }

    /// 读取「连接 + 库 + 表」记住的过滤条件（`09-filtering.md` §1.6）。
    public func tableFilter(database: String, table: String) -> FilterState? {
        guard services.preferences.rememberFilters else { return nil }
        return services.workspace.filter(connectionID: id, database: database, table: table)
    }

    /// 保存过滤条件；偏好关闭时忽略。
    public func saveTableFilter(database: String, table: String, filter: FilterState?) {
        guard services.preferences.rememberFilters else { return }
        services.workspace.setFilter(filter, connectionID: id, database: database, table: table)
    }

    public var activeTab: Tab? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID }
    }

    // MARK: 空闲判定

    /// 空闲超过阈值**且没有标签**才允许回收（05 §5）。
    public func isIdle(threshold: TimeInterval, now: Date? = nil) -> Bool {
        guard tabs.isEmpty else { return false }
        let current = now ?? services.clock.now
        return current.timeIntervalSince(lastActivity) >= threshold
    }

    /// 把标签状态导出。
    public func makeSessionState() -> SessionState {
        SessionState(
            connectionID: id,
            selectedDatabase: selectedDatabase,
            activeTabID: activeTabID,
            tabs: tabs.map { $0.snapshot() }
        )
    }

    /// 按 `session.json` 里这个连接的标签现场还原标签骨架（`05-session-management.md` §8）。
    public func restore(from state: SessionState) {
        selectedDatabase = state.selectedDatabase
        tabs = state.tabs.compactMap { Tab(state: $0) }
        nextQueryNumber = tabs.filter { $0.kind.isQuery }.count
        if let active = state.activeTabID, tabs.contains(where: { $0.id == active }) {
            activeTabID = active
        } else {
            activeTabID = tabs.first?.id
        }
    }

    // MARK: 私有

    private func noteActivity() {
        lastActivity = services.clock.now
    }

    private func resolvedMySQLPassword() -> String {
        if let mysqlPassword { return mysqlPassword }
        if let stored = try? services.credentials.password(for: id, kind: .mysqlPassword) {
            return stored
        }
        return ""
    }

    private func makeSSHSecret() -> SSHSecret? {
        guard connection.ssh.enabled, !connection.ssh.useSSHConfigAlias else { return nil }
        switch connection.ssh.authMethod {
        case .password:
            if let override = sshPassword, !override.isEmpty { return .password(override) }
            if let stored = try? services.credentials.password(for: id, kind: .sshPassword) {
                return .password(stored)
            }
            return nil
        case .privateKey:
            if let override = sshPassphrase, !override.isEmpty { return .passphrase(override) }
            if let stored = try? services.credentials.password(for: id, kind: .sshPassphrase) {
                return .passphrase(stored)
            }
            return nil
        case .sshConfigOrAgent:
            return nil
        }
    }

    /// 解析本次连接要用的 SSH 凭据：先查内存 / 钥匙串，都没有再按需向 UI 索要。
    ///
    /// - 密码认证缺密码、或加密私钥缺口令时，调 `sshSecretRequester` 弹窗；
    /// - 未加密的私钥不弹窗（`SSHPrivateKeyInspector` 预先判断）；
    /// - 用户取消时按「没有 secret」继续，让 ssh 自己报出确切错误。
    private func resolveSSHSecret() async -> SSHSecret? {
        if let existing = makeSSHSecret() { return existing }
        guard connection.ssh.enabled, !connection.ssh.useSSHConfigAlias else { return nil }

        let request: SSHSecretRequest
        switch connection.ssh.authMethod {
        case .password:
            request = SSHSecretRequest(
                kind: .password,
                connectionID: id,
                connectionName: connection.name,
                host: connection.ssh.host,
                port: connection.ssh.port
            )
        case .privateKey:
            let path = connection.ssh.privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty, SSHPrivateKeyInspector.isEncrypted(path: path) else { return nil }
            request = SSHSecretRequest(
                kind: .passphrase,
                connectionID: id,
                connectionName: connection.name,
                host: connection.ssh.host,
                port: connection.ssh.port,
                privateKeyPath: path
            )
        case .sshConfigOrAgent:
            return nil
        }

        guard let value = await sshSecretRequester?(request), !value.isEmpty else { return nil }
        switch request.kind {
        case .password:
            sshPassword = value
            return .password(value)
        case .passphrase:
            sshPassphrase = value
            return .passphrase(value)
        }
    }

    private func recordConnectFailure(_ failure: ConnectFailure) {
        guard recordsQueries else { return }
        let consoleLog = services.consoleLog
        Task { @MainActor in
            await consoleLog.record(
                tag: .meta,
                sql: "\(failure.step.displayName)：\(failure.underlyingMessage)",
                errorCode: failure.mysqlError?.code,
                errorMessage: failure.underlyingMessage
            )
        }
    }

    private func mysqlFailure(_ error: Error) -> ConnectFailure {
        if let failure = error as? ConnectFailure { return failure }
        if let mysqlError = error as? MySQLError {
            // 隧道已建立却连不上目标库：文案要说清是「从跳板机访问不到」，
            // 而不是笼统的网络 / 防火墙问题（`specs/10-ssh-tunnel.md` §5）。
            let tunneled = connection.ssh.enabled && mysqlError.kind == .connectionFailed
                ? HostPort(host: connection.mysql.host, port: connection.mysql.port)
                : nil
            return ConnectFailure(step: .mysql, reason: .mysql(mysqlError), tunneledMySQL: tunneled)
        }
        return ConnectFailure(step: .mysql, reason: .unknown(String(describing: error)))
    }

    private func sshFailure(_ error: Error) -> ConnectFailure {
        if let failure = error as? ConnectFailure { return failure }
        let endpoint = HostPort(host: connection.ssh.host, port: connection.ssh.port)
        if let tunnelError = error as? SSHTunnelError {
            return ConnectFailure(step: .sshTunnel, reason: .ssh(tunnelError), sshEndpoint: endpoint)
        }
        return ConnectFailure(step: .sshTunnel, reason: .unknown(String(describing: error)), sshEndpoint: endpoint)
    }

    private static func normalizedPort(_ port: Int) -> UInt32 {
        guard (1...65535).contains(port) else { return 3306 }
        return UInt32(port)
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
