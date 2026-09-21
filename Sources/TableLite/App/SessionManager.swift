import Combine
import Foundation
import os

// MARK: - SessionManager

/// 全局会话管理：唯一持有 `[ConnectionSession]` 的地方。
///
/// 设计见 `docs/tech-designs/05-session-management.md`：
/// - 切换连接不关闭会话；只有显式断开 / 空闲回收才关闭；
/// - 连接上限由偏好决定（默认 8），超出拒绝；
/// - 空闲超过 5 分钟**且没有标签**才回收；
/// - 连接失效不自动重连。
@MainActor
final class SessionManager: ObservableObject {

    /// 空闲回收检查周期。
    static let idleCheckInterval: TimeInterval = 30
    /// 空闲多久才允许回收（`specs/01-connections.md` §5）。
    static let idleThreshold: TimeInterval = 5 * 60

    @Published private(set) var sessions: [ConnectionSession] = []
    @Published var activeSessionID: UUID?

    let connections: ConnectionStore
    let credentials: CredentialStore
    let preferences: PreferencesStore
    let consoleLog: ConsoleLogStore
    let history: HistoryRepository

    private let clock: Clock
    private let fileSystem: FileSystemLocator
    private let sessionState: SessionStateStore
    private let drafts: DraftStore

    private var idleReaperTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    /// 每个会话一条观察订阅；删除连接时按 id 释放，避免已删会话被订阅链继续持有。
    private var sessionObservations: [UUID: AnyCancellable] = [:]

    init(connections: ConnectionStore,
         credentials: CredentialStore,
         preferences: PreferencesStore,
         consoleLog: ConsoleLogStore,
         history: HistoryRepository,
         clock: Clock,
         fileSystem: FileSystemLocator,
         sessionState: SessionStateStore? = nil,
         drafts: DraftStore? = nil) {
        self.connections = connections
        self.credentials = credentials
        self.preferences = preferences
        self.consoleLog = consoleLog
        self.history = history
        self.clock = clock
        self.fileSystem = fileSystem
        self.sessionState = sessionState ?? SessionStateStore(fileSystem: fileSystem)
        self.drafts = drafts ?? DraftStore(fileSystem: fileSystem, clock: clock)
    }

    // MARK: 查询

    var activeSession: ConnectionSession? {
        guard let activeSessionID else { return nil }
        return session(id: activeSessionID)
    }

    func session(id: UUID) -> ConnectionSession? {
        sessions.first { $0.id == id }
    }

    /// 正在占用资源的会话数（用于连接上限判断）：未连接的骨架不计数。
    var connectedSessionCount: Int {
        sessions.filter { $0.state != .disconnected }.count
    }

    // MARK: 连接

    /// 连接一个连接配置。若该连接已有会话，则复用并（必要时）重连。
    ///
    /// 达到偏好上限时抛 `MySQLError.unsupported`。
    func connect(_ connection: Connection, password: String?) async throws -> ConnectionSession {
        let resolved = resolvedPassword(connectionID: connection.id, provided: password)

        if let existing = session(id: connection.id) {
            activeSessionID = connection.id
            if existing.state == .connected { return existing }
            existing.updatePassword(resolved)
            try await existing.reconnect()
            await persistSessionState()
            return existing
        }

        guard connectedSessionCount < max(1, preferences.maxConnections) else {
            throw MySQLError.unsupported("同时保持的连接已达上限，请先断开一个不用的连接。")
        }

        let session = makeSession(connection: connection, password: resolved)
        sessions.append(session)
        activeSessionID = connection.id
        observe(session)

        do {
            try await session.open()
        } catch {
            // 失败保留会话对象与已建资源，状态已是 `.failed`。
            await persistSessionState()
            throw error
        }
        await persistSessionState()
        return session
    }

    func disconnect(id: UUID) async {
        guard let session = session(id: id) else { return }
        await session.close()
        await persistSessionState()
    }

    /// 删除连接时清理会话：停止观察 → 断开 → 从 `sessions` 移除 → 修正当前连接 → 落盘。
    ///
    /// 其余删除清理（`TableStateStore.removeAll` / Keychain 三个条目）由 `ConnectionsView` 负责。
    func removeSession(id: UUID) async {
        guard let session = session(id: id) else { return }
        sessionObservations[id] = nil
        // 查询草稿在标签关闭时才会删除；连接整体删除时这里补一刀，避免留下孤儿草稿文件。
        let draftIDs = session.tabs.compactMap(\.kind.draftID)
        await session.close()
        sessions.removeAll { $0.id == id }
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
        for draftID in draftIDs {
            do {
                try drafts.delete(draftID: draftID)
            } catch {
                storeLogger.error("删除连接时清理查询草稿失败：\(String(describing: error), privacy: .public)")
            }
        }
        await persistSessionState()
    }

    // MARK: 只读模式

    /// 切换只读模式并写回连接配置（`specs/09-readonly-mode.md` §6）。
    ///
    /// 关闭只读模式前的确认由调用方（菜单）负责；这里只负责会话状态与 `connections.json`
    /// 的同步，并刷新 `updatedAt`。
    func setReadOnly(connectionID: UUID, value: Bool) {
        guard let session = session(id: connectionID) else { return }
        session.setReadOnly(value)

        guard var connection = connections.connection(id: connectionID) else { return }
        guard connection.readOnly != value else { return }
        connection.readOnly = value
        connection.updatedAt = clock.now
        do {
            try connections.update(connection)
        } catch {
            storeLogger.error("只读状态写回连接配置失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 退出清理：同步等待所有隧道停止（`SSHTunnel.stop()` 内含 2s + SIGKILL）。
    func disconnectAll() async {
        idleReaperTask?.cancel()
        idleReaperTask = nil
        persistTask?.cancel()
        persistTask = nil
        for session in sessions {
            await session.close()
        }
    }

    func reconnect(id: UUID) async throws {
        guard let session = session(id: id) else { return }
        let password = try? credentials.retrieve(CredentialKey(kind: .mysqlPassword, connectionID: id))
        session.updatePassword(password)
        try await session.reconnect()
        await persistSessionState()
    }

    // MARK: 空闲回收

    /// 每 30s 检查一次：空闲 > 5 分钟且没有标签的会话才断开。
    func startIdleReaper() {
        guard idleReaperTask == nil else { return }
        idleReaperTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await self.clock.sleep(seconds: Self.idleCheckInterval)
                guard !Task.isCancelled else { return }
                await self.reapIdleSessions()
            }
        }
    }

    private func reapIdleSessions() async {
        guard preferences.idleDisconnect else { return }
        for session in sessions {
            guard session.tabs.isEmpty else { continue }
            guard session.state != .disconnected else { continue }
            guard session.isIdle(threshold: Self.idleThreshold) else { continue }
            await session.close()
        }
    }

    // MARK: 会话恢复

    /// 启动时按 `session.json` 恢复骨架，**不自动连接**。
    /// `preferences.restoreSession` 关闭时不恢复，并清理孤儿草稿。
    func restoreIfNeeded() async {
        guard sessions.isEmpty else { return }

        guard preferences.restoreSession else {
            try? drafts.removeOrphans(referenced: [])
            return
        }

        let state: SessionStateStore.State
        do {
            guard let loaded = try sessionState.load() else { return }
            state = loaded
        } catch {
            storeLogger.error("session.json 读取失败：\(String(describing: error), privacy: .public)")
            return
        }

        let referenced = Set(state.sessions.flatMap { $0.tabs.compactMap(\.draftID) })
        do {
            try drafts.removeOrphans(referenced: referenced)
        } catch {
            storeLogger.error("孤儿草稿清理失败：\(String(describing: error), privacy: .public)")
        }

        for snapshot in state.sessions {
            guard let connection = connections.connection(id: snapshot.connectionID) else { continue }
            let session = makeSession(connection: connection, password: nil)
            session.selectedDatabase = snapshot.selectedDatabase
            session.restoreTabs(from: snapshot.tabs, activeIndex: snapshot.activeTabIndex)
            sessions.append(session)
            observe(session)
        }

        if let activeID = state.activeConnectionID, session(id: activeID) != nil {
            activeSessionID = activeID
        } else {
            activeSessionID = sessions.first?.id
        }
    }

    /// 把当前会话 / 标签骨架写入 `session.json`。偏好关闭时跳过。
    func persistSessionState() async {
        guard preferences.restoreSession else { return }

        let snapshots = sessions.map { session in
            SessionStateStore.SessionSnapshot(
                connectionID: session.id,
                selectedDatabase: session.selectedDatabase,
                activeTabIndex: session.tabs.firstIndex { $0.id == session.activeTabID },
                tabs: session.tabs.compactMap(Self.tabSnapshot(for:))
            )
        }
        let state = SessionStateStore.State(schemaVersion: SessionStateStore.schemaVersion,
                                            activeConnectionID: activeSessionID,
                                            sessions: snapshots)
        do {
            try sessionState.save(state)
        } catch {
            storeLogger.error("session.json 写入失败：\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 私有

    /// 调用方未显式给密码时回落到 Keychain（密码绝不出现在连接配置里）。
    private func resolvedPassword(connectionID: UUID, provided: String?) -> String? {
        if let provided { return provided }
        return try? credentials.retrieve(CredentialKey(kind: .mysqlPassword, connectionID: connectionID))
    }

    private func makeSession(connection: Connection, password: String?) -> ConnectionSession {
        ConnectionSession(connection: connection,
                          password: password,
                          credentials: credentials,
                          preferences: preferences,
                          consoleLog: consoleLog,
                          drafts: drafts,
                          clock: clock,
                          fileSystem: fileSystem)
    }

    /// 订阅会话变化，防抖后落盘 `session.json`。
    private func observe(_ session: ConnectionSession) {
        let id = session.id
        sessionObservations[id] = session.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.schedulePersist()
                }
            }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(seconds: 0.5)
            guard !Task.isCancelled else { return }
            await self.persistSessionState()
        }
    }

    private static func tabSnapshot(for tab: Tab) -> SessionStateStore.TabSnapshot? {
        switch tab.kind {
        case .tableData(let ref):
            return SessionStateStore.TabSnapshot(kind: "tableData",
                                                 database: ref.database,
                                                 objectName: ref.table)
        case .tableStructure(let ref):
            return SessionStateStore.TabSnapshot(kind: "tableStructure",
                                                 database: ref.database,
                                                 objectName: ref.table)
        case .objectDefinition(let ref, _):
            return SessionStateStore.TabSnapshot(kind: "objectDefinition",
                                                 database: ref.database,
                                                 objectName: ref.table)
        case .query(let draftID):
            return SessionStateStore.TabSnapshot(kind: "query", draftID: draftID)
        case .history, .consoleLog:
            // 这两个标签不持久化（重启后按需重新打开）。
            return nil
        }
    }
}
