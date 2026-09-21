import Foundation

/// 单张表的列布局（列宽 / 列显隐）。
///
/// `specs/03-data-browsing.md` §5、`specs/11-preferences.md` §3：宽度与显隐按「连接 + 库 + 表」记住。
public struct TableLayout: Sendable, Codable, Equatable {

    /// 列名 → 宽度（pt）。
    public var columnWidths: [String: Double]
    /// 被隐藏的列名。
    public var hiddenColumns: [String]

    public init(columnWidths: [String: Double] = [:], hiddenColumns: [String] = []) {
        self.columnWidths = columnWidths
        self.hiddenColumns = hiddenColumns
    }

    public var isEmpty: Bool {
        columnWidths.isEmpty && hiddenColumns.isEmpty
    }
}

/// 窗口与工作区状态。
///
/// `02-persistence.md` §7：窗口 frame 用 `NSWindow.setFrameAutosaveName`（这里只提供名字常量，
/// AppKit 调用由 UI 层做）；单窗口应用。
///
/// `02-persistence.md` §6：与连接 / 表绑定的状态（列宽、列显隐、过滤器）用
/// 连接 id + `schema.table` 作为键的一部分，存在 `UserDefaults` 里。
///
/// 并发：`@MainActor`，因为它直接持有 `@MainActor` 的 `KeyValueStore`。
@MainActor
public final class WorkspaceStateStore {

    /// 主窗口 frame 自动保存名，UI 层传给 `NSWindow.setFrameAutosaveName`。
    public static let windowFrameAutosaveName = "TableLite.MainWindow"

    /// 存储键。
    public enum Key {
        public static let tableLayouts = "workspace.tableLayouts"
        public static let tableFilters = "workspace.tableFilters"
    }

    private let store: KeyValueStore
    private var tableLayouts: [String: TableLayout]
    private var tableFilters: [String: FilterState]

    public init(store: KeyValueStore) {
        self.store = store
        self.tableLayouts = Self.decode([String: TableLayout].self, from: store, key: Key.tableLayouts) ?? [:]
        self.tableFilters = Self.decode([String: FilterState].self, from: store, key: Key.tableFilters) ?? [:]
    }

    // MARK: - 列布局

    public func layout(connectionID: UUID, database: String, table: String) -> TableLayout? {
        tableLayouts[Self.key(connectionID: connectionID, database: database, table: table)]
    }

    /// 写入列布局；传 `nil` 或空布局表示删除。
    public func setLayout(_ layout: TableLayout?, connectionID: UUID, database: String, table: String) {
        let key = Self.key(connectionID: connectionID, database: database, table: table)
        if let layout, !layout.isEmpty {
            tableLayouts[key] = layout
        } else {
            tableLayouts.removeValue(forKey: key)
        }
        persist(tableLayouts, key: Key.tableLayouts)
    }

    // MARK: - 过滤器

    public func filter(connectionID: UUID, database: String, table: String) -> FilterState? {
        tableFilters[Self.key(connectionID: connectionID, database: database, table: table)]
    }

    /// 写入过滤器；传 `nil` 或空状态表示删除。
    public func setFilter(_ filter: FilterState?, connectionID: UUID, database: String, table: String) {
        let key = Self.key(connectionID: connectionID, database: database, table: table)
        if let filter, filter.isActive || filter.isVisible {
            tableFilters[key] = filter
        } else {
            tableFilters.removeValue(forKey: key)
        }
        persist(tableFilters, key: Key.tableFilters)
    }

    // MARK: - 清理

    /// 删除某个连接的全部表级状态（删除连接时调用）。
    public func removeAll(connectionID: UUID) {
        let prefix = connectionID.uuidString.lowercased() + "|"
        tableLayouts = tableLayouts.filter { !$0.key.hasPrefix(prefix) }
        tableFilters = tableFilters.filter { !$0.key.hasPrefix(prefix) }
        persist(tableLayouts, key: Key.tableLayouts)
        persist(tableFilters, key: Key.tableFilters)
    }

    /// 清空全部表级状态。
    public func removeAll() {
        tableLayouts.removeAll()
        tableFilters.removeAll()
        store.removeObject(forKey: Key.tableLayouts)
        store.removeObject(forKey: Key.tableFilters)
    }

    // MARK: - 内部

    private static func key(connectionID: UUID, database: String, table: String) -> String {
        "\(connectionID.uuidString.lowercased())|\(database)|\(table)"
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            store.set(data, forKey: key)
        } catch {
            StoreLog.error("保存工作区状态失败（\(key)）：\(error)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from store: KeyValueStore, key: String) -> T? {
        guard let data = store.object(forKey: key) as? Data else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // 向前兼容读取（`02-persistence.md` §9）：解析不了就当没有。
            StoreLog.warning("读取工作区状态失败（\(key)）：\(error)")
            return nil
        }
    }
}
