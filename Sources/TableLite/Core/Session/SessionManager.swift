import Foundation
import Observation

/// 全局会话管理：**唯一**持有 `[ConnectionSession]` 的地方。
///
/// 设计见 `docs/tech-designs/05-session-management.md` §2：
/// - 切换连接不关闭会话；只有显式断开或空闲回收才关闭；
/// - 连接上限由偏好决定（默认 8），超出时拒绝并提示；
/// - 空闲 > 5 分钟**且没有标签**才回收；
/// - 连接失效不自动重连（L7）。
@MainActor
@Observable
public final class SessionManager {

    /// 空闲回收检查周期。
    public static let idleCheckInterval: TimeInterval = 30
    /// 空闲多久才允许回收（`specs/01-connections.md` §5）。
    public static let idleThreshold: TimeInterval = 5 * 60
    /// 保活检查周期（秒）。实际值取自偏好「心跳间隔」（`specs/11-preferences.md` §2）。
    public static let defaultKeepAliveCheckInterval: TimeInterval = 30

    public private(set) var sessions: [ConnectionSession] = []
    public var activeSessionID: UUID?

    @ObservationIgnored private let connections: ConnectionStore
    @ObservationIgnored private let services: SessionServices
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// 启动时从 `session.json` 读出的「按连接标签现场」，连接时套用（05 §8）。
    @ObservationIgnored private var loadedTagSnapshots: [UUID: SessionState] = [:]
    @ObservationIgnored private var didLoadTagSnapshots = false
    /// 需要 SSH 凭据时转发给会话的弹窗挂载点（`specs/10-ssh-tunnel.md` §3.2 / §3.3）。
    @ObservationIgnored public var sshSecretRequester: (@MainActor (SSHSecretRequest) async -> String?)?

    public init(connections: ConnectionStore, services: SessionServices) {
        self.connections = connections
        self.services = services
    }

    // MARK: 查询

    public var activeSession: ConnectionSession? {
        guard let activeSessionID else { return nil }
        return session(id: activeSessionID)
    }

    public func session(id: UUID) -> ConnectionSession? {
        sessions.first { $0.id == id }
    }

    /// 正在占用服务器连接的会话数（连接上限判断用）：未连接 / 已回收的骨架不计数。
    public var activeSessionCount: Int {
        sessions.filter { $0.state.holdsResources }.count
    }

    /// 连接上限。
    public var connectionLimit: Int {
        max(1, services.preferences.maxSessions)
    }

    // MARK: 连接

    /// 连接一个连接配置。已有会话时复用；达到上限时抛错。
    ///
    /// `sshSecrets` 是表单刚输入、尚未写入钥匙串的 SSH 凭据（可选）。
    @discardableResult
    public func connect(
        _ connection: Connection,
        password: String?,
        sshSecrets: SSHSecrets? = nil
    ) async throws -> ConnectionSession {
        if let existing = session(id: connection.id) {
            activeSessionID = connection.id
            existing.sshSecretRequester = sshSecretRequester
            let needsReconnect = existing.updateConnection(connection)
            if let password { existing.updatePassword(password) }
            if let sshSecrets { existing.setSSHSecrets(password: sshSecrets.password, passphrase: sshSecrets.passphrase) }
            if existing.state.isConnected, !needsReconnect { return existing }
            try await existing.reconnect()
            await persistSessionState()
            return existing
        }

        guard activeSessionCount < connectionLimit else {
            throw SessionManagerError.connectionLimitReached(limit: connectionLimit)
        }
        // 保险：启动早期就点连接时也先读到旧现场。
        await loadTagSnapshotsIfNeeded()

        let session = ConnectionSession(connection: connection, password: password, services: services)
        session.sshSecretRequester = sshSecretRequester
        if let sshSecrets { session.setSSHSecrets(password: sshSecrets.password, passphrase: sshSecrets.passphrase) }
        sessions.append(session)
        activeSessionID = connection.id
        // 套用这个连接上次的标签现场（S36）；失败时也不丢，用户重连后还在。
        let tagSnapshot = loadedTagSnapshots[connection.id]
        if let tagSnapshot { session.restore(from: tagSnapshot) }
        do {
            try await session.open()
        } catch {
            // 失败保留会话对象与已建资源，状态已是 `.failed`。
            await persistSessionState()
            throw error
        }
        if tagSnapshot != nil {
            // 还原出来的表数据标签需要重新加载。
            await session.reloadTabsAfterReconnect()
        }
        await persistSessionState()
        return session
    }

    /// 显式断开。
    public func disconnect(id: UUID) async {
        guard let session = session(id: id) else { return }
        await session.close()
        await persistSessionState()
    }

    /// 「重新连接」。必要时重建隧道与 MySQL 连接；暂存改动不清空。
    public func reconnect(id: UUID) async throws {
        guard let session = session(id: id) else {
            throw SessionManagerError.sessionNotFound(id)
        }
        if let stored = try? services.credentials.password(for: id, kind: .mysqlPassword) {
            session.updatePassword(stored)
        }
        try await session.reconnect()
        await persistSessionState()
    }

    /// 「恢复全部」：把所有未连接的会话逐个重连；失败不打断后续。
    public func reconnectAll() async {
        for session in sessions where !session.state.isConnected {
            do {
                try await reconnect(id: session.id)
            } catch {
                StoreLog.error("恢复连接 \(session.connection.name) 失败：\(error)")
            }
        }
    }

    /// 删除连接时清理会话（断开、移除、清理草稿），并丢掉它的标签现场。
    public func removeSession(id: UUID) async {
        loadedTagSnapshots[id] = nil
        guard let session = session(id: id) else {
            // 没有会话（本次运行没连过）也要把快照从文件里抹掉。
            await persistSessionState()
            return
        }
        let draftIDs = session.tabs.compactMap(\.kind.draftID)
        await session.close()
        sessions.removeAll { $0.id == id }
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
        for draftID in draftIDs {
            try? await services.drafts.delete(id: draftID)
        }
        await persistSessionState()
    }

    // MARK: 测试连接（05 §3.1）

    /// 走与正式连接同一条代码路径，完成后立即关闭；不进 `sessions`、不写查询历史。
    ///
    /// 测试面板不回走 SSH 凭据弹窗（表单已提供密码，私钥口令由正式连接时再问），
    /// 避免与「测试连接」结果面板叠两个 sheet。
    public func testConnection(
        _ connection: Connection,
        password: String?,
        sshSecrets: SSHSecrets? = nil
    ) async -> ConnectionTestReport {
        let session = ConnectionSession(
            connection: connection,
            password: password,
            services: services,
            recordsQueries: false
        )
        if let sshSecrets {
            session.setSSHSecrets(password: sshSecrets.password, passphrase: sshSecrets.passphrase)
        }
        do {
            try await session.open()
            let report = ConnectionTestReport.success(
                serverInfo: session.serverInfo,
                unresolvedDatabase: session.unresolvedDatabase,
                sshEnabled: connection.ssh.enabled,
                tunnelLocalPort: session.tunnelEndpoint?.port
            )
            await session.close()
            return report
        } catch let failure as ConnectFailure {
            await session.close()
            return ConnectionTestReport.failed(failure, sshEnabled: connection.ssh.enabled)
        } catch {
            await session.close()
            let failure = ConnectFailure(step: .mysql, reason: .unknown(String(describing: error)))
            return ConnectionTestReport.failed(failure, sshEnabled: connection.ssh.enabled)
        }
    }

    // MARK: 空闲回收（05 §5）

    public func startIdleReaper() {
        guard idleTask == nil else { return }
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.idleCheckInterval))
                guard !Task.isCancelled else { return }
                await self?.reapIdleSessions()
            }
        }
    }

    public func stopIdleReaper() {
        idleTask?.cancel()
        idleTask = nil
    }

    /// 执行一次回收判定（单测与手动触发）。
    public func reapIdleSessions(now: Date? = nil) async {
        guard services.preferences.idleDisconnect else { return }
        for session in sessions {
            guard session.tabs.isEmpty else { continue }
            guard session.state.holdsResources else { continue }
            guard session.isIdle(threshold: Self.idleThreshold, now: now) else { continue }
            await session.recycleResources()
        }
    }

    // MARK: 保活（03 §6）

    public func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = max(1, self?.services.preferences.keepAliveInterval ?? Int(Self.defaultKeepAliveCheckInterval))
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.pingActiveSessions()
            }
        }
    }

    public func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// 对所有已连接且开启保活的会话发一次心跳；失败在会话侧标记失效。
    public func pingActiveSessions() async {
        for session in sessions where session.state.isConnected {
            guard session.connection.mysql.keepAlive else { continue }
            await session.ping()
        }
    }

    // MARK: 标签现场（05 §8）

    /// 启动时读 `session.json`，只把「按连接的标签现场」装进内存。
    ///
    /// **不建会话、不自动连接**（决策 S36）：每次启动都进连接列表，
    /// 用户在连接列表里连上某个连接时才套用它上次的标签。
    ///
    /// 顺带清理超过 30 天且未被引用的孤儿草稿（§9）。
    public func loadTagSnapshotsIfNeeded() async {
        guard !didLoadTagSnapshots else { return }
        didLoadTagSnapshots = true

        let file: SessionStateFile
        do {
            guard let loaded = try await services.sessionState.load() else {
                _ = try? await services.drafts.cleanupOrphans(referencedIDs: [])
                return
            }
            file = loaded
        } catch {
            StoreLog.error("读取 session.json 失败：\(error)")
            return
        }

        let referenced = SessionStateStore.referencedDraftIDs(in: file)
        do {
            _ = try await services.drafts.cleanupOrphans(referencedIDs: referenced)
        } catch {
            StoreLog.error("清理孤儿草稿失败：\(error)")
        }

        for snapshot in file.sessions {
            // 连接已被删掉的旧快照留着没用。
            guard let _ = try? await connections.connection(id: snapshot.connectionID) else { continue }
            loadedTagSnapshots[snapshot.connectionID] = snapshot
        }
    }

    /// 把「按连接的标签现场」写入 `session.json`。
    ///
    /// 读-改-写：本次运行打开过的连接以当前会话为准（标签清空也写空快照，避免下次又还原出旧标签）；
    /// 没打开过的连接的旧快照原样保留（`05-session-management.md` §8）。
    public func persistSessionState() async {
        // 没先读过就写会把别人的快照冲掉（启动早期调用）。
        await loadTagSnapshotsIfNeeded()

        var snapshots = loadedTagSnapshots
        for session in sessions {
            snapshots[session.id] = session.makeSessionState()
        }
        let file = SessionStateFile(
            activeConnectionID: activeSessionID,
            sessions: snapshots.values.sorted { $0.connectionID.uuidString < $1.connectionID.uuidString }
        )
        do {
            try await services.sessionState.save(file)
        } catch {
            StoreLog.error("写入 session.json 失败：\(error)")
        }
    }

    /// 防抖落盘；标签状态频繁变化时用。
    public func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            await self?.persistSessionState()
        }
    }

    // MARK: 退出清理（05 §7）

    /// 关闭所有 MySQL 会话、停止所有隧道、flush Console Log。
    ///
    /// 供 `AppDelegate` 的 `applicationShouldTerminate(.terminateLater)` 调用。
    public func prepareForTermination() async {
        stopIdleReaper()
        stopKeepAlive()
        persistTask?.cancel()
        persistTask = nil
        await persistSessionState()
        for session in sessions {
            await session.close()
        }
        await services.consoleLog.flush()
    }
}
