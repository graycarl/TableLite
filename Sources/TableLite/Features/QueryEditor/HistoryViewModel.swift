import Combine
import Foundation
import os

// MARK: - HistoryViewModel

/// 查询历史面板的 ViewModel。见 `docs/tech-designs/02-persistence.md` §4、
/// `specs/06-query-editor.md` §5。
///
/// - 数据来自 `HistoryRepository`（`history.sqlite3`），本 VM 不做写入；
/// - 历史只由 `QueryTabViewModel` 在执行 SQL 编辑器语句时写入；
/// - 连接下拉用注入的 `ConnectionStore?` 取名字（不引用 `ConnectionSession` / `Tab`）。
@MainActor
final class HistoryViewModel: ObservableObject {

    /// 面板一次展示的条数上限（「结果限量」）。更早的靠搜索缩小。
    static let reloadLimit = 500

    /// 打开面板时所在的连接，供 View 做默认高亮 / 「清空当前连接」。
    let currentConnectionID: UUID

    @Published var searchText: String = "" {
        didSet { scheduleReload() }
    }

    @Published var connectionFilter: UUID? {
        didSet { scheduleReload() }
    }

    @Published private(set) var entries: [HistoryRepository.Entry] = []

    @Published var selectedEntry: HistoryRepository.Entry?

    private let connections: ConnectionStore?
    private let history: HistoryRepository
    private let clock: Clock

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "mysql")
    private var reloadTask: Task<Void, Never>?

    init(connectionID: UUID,
         connections: ConnectionStore?,
         history: HistoryRepository,
         clock: Clock) {
        self.currentConnectionID = connectionID
        self.connections = connections
        self.history = history
        self.clock = clock
    }

    // MARK: 数据

    /// 连接下拉用；`ConnectionStore` 缺失时为空。
    var availableConnections: [Connection] {
        connections?.connections ?? []
    }

    func displayName(for connectionID: UUID) -> String {
        if let connection = connections?.connection(id: connectionID) {
            return connection.name.isEmpty ? connection.mysql.host : connection.name
        }
        return String(connectionID.uuidString.prefix(8))
    }

    func reload() async {
        do {
            entries = try history.recent(connectionID: connectionFilter,
                                         search: searchText,
                                         limit: Self.reloadLimit)
            if let selected = selectedEntry, !entries.contains(selected) {
                selectedEntry = nil
            }
        } catch {
            logger.error("读取查询历史失败：\(String(describing: error), privacy: .public)")
        }
    }

    func delete(_ entry: HistoryRepository.Entry) async {
        do {
            try history.delete(id: entry.id)
        } catch {
            logger.error("删除查询历史失败：\(String(describing: error), privacy: .public)")
        }
        if selectedEntry == entry { selectedEntry = nil }
        await reload()
    }

    /// `connectionID == nil` 时清空全部（UI 的 `⌥` 清空所有连接）。
    func clear(connectionID: UUID?) async {
        do {
            try history.clear(connectionID: connectionID)
        } catch {
            logger.error("清空查询历史失败：\(String(describing: error), privacy: .public)")
        }
        selectedEntry = nil
        await reload()
    }

    // MARK: 私有

    /// 搜索 / 过滤切换时轻微防抖，避免每次击键都打一次 SQLite。
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(seconds: 0.15)
            guard !Task.isCancelled else { return }
            await self.reload()
        }
    }
}
