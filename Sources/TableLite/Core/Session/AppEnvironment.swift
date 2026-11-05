import Foundation
import Observation

/// 应用根对象：组装全部 Store + 偏好 + `SessionManager`，注入 SwiftUI environment。
///
/// 状态归属见 `docs/tech-designs/06-ui-layer.md` §2：`AppEnvironment` 在启动时创建并注入，
/// 持有偏好、连接仓库、历史仓库、Console Log 与 `SessionManager`；没有全局单例。
/// 调试 profile 的装配错误（`15-testing.md` §9.1）。
public enum AppEnvironmentError: Error, CustomStringConvertible {
    case incompleteDevProfile
    case invalidDefaultsSuite(String)

    public var description: String {
        switch self {
        case .incompleteDevProfile:
            return "调试 profile 必须同时指定数据目录与偏好 suite"
        case .invalidDefaultsSuite(let suite):
            return "无法创建 UserDefaults suite「\(suite)」"
        }
    }
}

@MainActor
@Observable
public final class AppEnvironment {

    public let layout: AppStorageLayout
    public let preferences: Preferences
    public let connections: ConnectionStore
    public let credentials: CredentialStore
    public let consoleLog: ConsoleLogStore
    public let history: QueryHistoryStore
    public let sessionState: SessionStateStore
    public let drafts: QueryDraftStore
    public let workspace: WorkspaceStateStore
    public let sessionManager: SessionManager
    public let clock: Clock

    /// 是否在调试 profile 里运行（`15-testing.md` §9.1，仅 Debug 构建可能为 true）。
    public let isDevProfile: Bool
    /// 调试 profile 用的 `UserDefaults` suite 名；nil 表示标准域。
    public let defaultsSuiteName: String?

    /// 窗口 frame 自动保存名。调试 profile 必须带后缀，
    /// 因为 `setFrameAutosaveName` 走 UserDefaults 标准域，不受 suite 隔离（`15-testing.md` §9.1）。
    public var windowFrameAutosaveName: String {
        isDevProfile
            ? WorkspaceStateStore.windowFrameAutosaveName + "-dev"
            : WorkspaceStateStore.windowFrameAutosaveName
    }

    @ObservationIgnored private var didStart = false

    public init(
        layout: AppStorageLayout,
        preferences: Preferences,
        connections: ConnectionStore,
        credentials: CredentialStore,
        consoleLog: ConsoleLogStore,
        history: QueryHistoryStore,
        sessionState: SessionStateStore,
        drafts: QueryDraftStore,
        workspace: WorkspaceStateStore,
        clock: Clock,
        factory: SessionBackendFactory,
        isDevProfile: Bool = false,
        defaultsSuiteName: String? = nil
    ) {
        self.layout = layout
        self.preferences = preferences
        self.connections = connections
        self.credentials = credentials
        self.consoleLog = consoleLog
        self.history = history
        self.sessionState = sessionState
        self.drafts = drafts
        self.workspace = workspace
        self.clock = clock
        self.isDevProfile = isDevProfile
        self.defaultsSuiteName = defaultsSuiteName
        let services = SessionServices(
            preferences: preferences,
            consoleLog: consoleLog,
            history: history,
            drafts: drafts,
            sessionState: sessionState,
            workspace: workspace,
            credentials: credentials,
            clock: clock,
            factory: factory
        )
        self.sessionManager = SessionManager(connections: connections, services: services)
    }

    // MARK: 组装

    /// 真实运行环境。失败时回退到临时目录，保证 App 仍能启动。
    public static func makeLiveOrFallback() -> AppEnvironment {
        do {
            return try live()
        } catch {
            StoreLog.error("初始化存储失败，回退到临时目录：\(error)")
            return makeFallback()
        }
    }

    /// 真实运行环境（`Application Support/TableLite` + 凭据文件 + UserDefaults）。
    public static func live() throws -> AppEnvironment {
        try live(dataDirectory: nil, defaultsSuite: nil)
    }

    /// 真实运行环境的可覆盖版本：把存储根与偏好域指向别处。
    ///
    /// 只供 Debug 调试 profile 使用（`15-testing.md` §9.1）；两者都 `nil` 等价于 `live()`。
    /// **参数必须成组给**：只覆盖数据目录、偏好仍写标准域的话，调试会污染真实偏好（S51 例外）。
    /// suite 无法创建时抛错，**不静默回落到标准域**——否则 agent 会以为自己在隔离环境里。
    public static func live(dataDirectory: URL?, defaultsSuite: String?) throws -> AppEnvironment {
        guard (dataDirectory == nil) == (defaultsSuite == nil) else {
            throw AppEnvironmentError.incompleteDevProfile
        }
        let layout: AppStorageLayout
        if let dataDirectory {
            try AtomicFileWriter.ensureDirectory(dataDirectory)
            layout = AppStorageLayout(rootDirectory: dataDirectory)
        } else {
            layout = try AppStorageLayout.live()
        }
        let keyValue: KeyValueStore
        if let defaultsSuite {
            // 空 suite 在 `UserDefaults(suiteName:)` 上是未定义行为（可能回落标准域），显式拒绝。
            guard !defaultsSuite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let defaults = UserDefaults(suiteName: defaultsSuite) else {
                throw AppEnvironmentError.invalidDefaultsSuite(defaultsSuite)
            }
            keyValue = UserDefaultsKeyValueStore(defaults: defaults)
        } else {
            keyValue = UserDefaultsKeyValueStore()
        }
        let clock = SystemClock()
        let preferences = Preferences(store: keyValue)
        let credentials = FileCredentialStore(layout: layout)
        let connections = ConnectionStore(layout: layout, credentials: credentials)
        let consoleLog = ConsoleLogStore(
            capacity: preferences.consoleLogCapacity,
            clock: clock,
            fileWriter: preferences.consoleLogWriteToFile
                ? ConsoleLogFileWriter(directory: layout.consoleLogDirectory, clock: clock)
                : nil
        )
        return AppEnvironment(
            layout: layout,
            preferences: preferences,
            connections: connections,
            credentials: credentials,
            consoleLog: consoleLog,
            history: QueryHistoryStore(layout: layout),
            sessionState: SessionStateStore(layout: layout),
            drafts: QueryDraftStore(layout: layout, clock: clock),
            workspace: WorkspaceStateStore(store: keyValue),
            clock: clock,
            factory: .live,
            isDevProfile: dataDirectory != nil || defaultsSuite != nil,
            defaultsSuiteName: defaultsSuite
        )
    }

    /// 存储不可用时的兜底环境：临时目录 + 内存键值 / 凭据。
    public static func makeFallback() -> AppEnvironment {
        let layout = AppStorageLayout(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("TableLiteFallback-\(UUID().uuidString)", isDirectory: true)
        )
        let clock = SystemClock()
        let credentials = InMemoryCredentialStore()
        return AppEnvironment(
            layout: layout,
            preferences: Preferences(store: InMemoryKeyValueStore()),
            connections: ConnectionStore(layout: layout, credentials: credentials),
            credentials: credentials,
            consoleLog: ConsoleLogStore(capacity: 5000, clock: clock),
            history: QueryHistoryStore(layout: layout),
            sessionState: SessionStateStore(layout: layout),
            drafts: QueryDraftStore(layout: layout, clock: clock),
            workspace: WorkspaceStateStore(store: InMemoryKeyValueStore()),
            clock: clock,
            factory: .live
        )
    }

    // MARK: 生命周期

    /// 启动时装配：读入标签现场（不建会话、不自动连接）、清理孤儿草稿、启动空闲回收与保活。
    public func start() async {
        guard !didStart else { return }
        didStart = true
        await sessionManager.loadTagSnapshotsIfNeeded()
        sessionManager.startIdleReaper()
        sessionManager.startKeepAlive()
    }

    /// 退出清理。见 `docs/tech-designs/05-session-management.md` §7。
    public func prepareForTermination() async {
        await sessionManager.prepareForTermination()
    }

    // MARK: 偏好联动

    /// 把 Console Log 的容量与落盘偏好应用到运行中的 `ConsoleLogStore`（改了立刻生效）。
    ///
    /// 容量直接重建环形缓冲；落盘只在开关跳变时创建 / 释放 `ConsoleLogFileWriter`，
    /// 避免每次偏好变更都泄漏一个 actor。
    public func syncConsoleLogSettings() {
        consoleLog.setCapacity(preferences.consoleLogCapacity)
        if preferences.consoleLogWriteToFile {
            guard !consoleLog.hasFileWriter else { return }
            consoleLog.setFileWriter(ConsoleLogFileWriter(directory: layout.consoleLogDirectory, clock: clock))
        } else {
            guard consoleLog.hasFileWriter else { return }
            consoleLog.setFileWriter(nil)
        }
    }
}
