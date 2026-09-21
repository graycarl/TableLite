import Foundation
import os

// MARK: - AppEnvironment

/// App 启动时创建并注入的依赖容器。
///
/// 见 `docs/tech-designs/06-ui-layer.md` §2：
/// - `AppEnvironment` 持有偏好、连接仓库、历史仓库、Console Log、`SessionManager`；
/// - `SessionManager` 是唯一可变根状态；
/// - 没有全局单例。
///
/// 视图只读这里的状态、只发意图。退出清理见 `docs/tech-designs/05-session-management.md` §7。
@MainActor
final class AppEnvironment: ObservableObject {

    let clock: Clock
    let fileSystem: FileSystemLocator
    let credentials: CredentialStore
    let preferences: PreferencesStore
    let connections: ConnectionStore
    let history: HistoryRepository
    let consoleLog: ConsoleLogStore
    let drafts: DraftStore
    let sessionState: SessionStateStore
    let tableState: TableStateStore
    let sessionManager: SessionManager

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "app")

    init(clock: Clock,
         fileSystem: FileSystemLocator,
         credentials: CredentialStore,
         preferences: PreferencesStore,
         connections: ConnectionStore,
         history: HistoryRepository,
         consoleLog: ConsoleLogStore,
         drafts: DraftStore,
         sessionState: SessionStateStore,
         tableState: TableStateStore,
         sessionManager: SessionManager) {
        self.clock = clock
        self.fileSystem = fileSystem
        self.credentials = credentials
        self.preferences = preferences
        self.connections = connections
        self.history = history
        self.consoleLog = consoleLog
        self.drafts = drafts
        self.sessionState = sessionState
        self.tableState = tableState
        self.sessionManager = sessionManager
    }

    /// 生产环境装配。`ConnectionStore.load()` 失败不 crash：记录后按空列表继续，
    /// 具体错误由 Wave 4 的界面展示。
    static func live() -> AppEnvironment {
        let clock = LiveClock()
        let fileSystem = LiveFileSystemLocator()
        let credentials = KeychainCredentialStore()
        let preferences = PreferencesStore()

        let connections = ConnectionStore(fileSystem: fileSystem)
        do {
            try connections.load()
        } catch {
            storeLogger.error("connections.json 读取失败：\(String(describing: error), privacy: .public)")
        }

        let history = HistoryRepository(fileSystem: fileSystem, clock: clock)
        let consoleLog = ConsoleLogStore(capacity: preferences.consoleLogCapacity,
                                         clock: clock,
                                         fileSystem: fileSystem,
                                         writeToFile: preferences.consoleLogWriteToFile)
        let drafts = DraftStore(fileSystem: fileSystem, clock: clock)
        let sessionState = SessionStateStore(fileSystem: fileSystem)
        let tableState = TableStateStore()

        let sessionManager = SessionManager(connections: connections,
                                            credentials: credentials,
                                            preferences: preferences,
                                            consoleLog: consoleLog,
                                            history: history,
                                            clock: clock,
                                            fileSystem: fileSystem,
                                            sessionState: sessionState,
                                            drafts: drafts)

        let environment = AppEnvironment(clock: clock,
                                         fileSystem: fileSystem,
                                         credentials: credentials,
                                         preferences: preferences,
                                         connections: connections,
                                         history: history,
                                         consoleLog: consoleLog,
                                         drafts: drafts,
                                         sessionState: sessionState,
                                         tableState: tableState,
                                         sessionManager: sessionManager)

        // 启动按 session.json 恢复骨架（不自动连接），并开始空闲回收。
        Task { await sessionManager.restoreIfNeeded() }
        sessionManager.startIdleReaper()
        return environment
    }

    /// 退出前调用：处理未提交改动由 UI 负责，这里只做资源清理
    /// （持久化会话骨架 → 关闭所有 MySQL 会话、停止所有隧道 → flush Console Log）。
    func shutdown() async {
        logger.info("TableLite 退出清理开始")
        await sessionManager.persistSessionState()
        await sessionManager.disconnectAll()
        do {
            try consoleLog.flushToDisk()
        } catch {
            storeLogger.error("Console Log 落盘失败：\(String(describing: error), privacy: .public)")
        }
        logger.info("TableLite 退出清理完成")
    }
}
