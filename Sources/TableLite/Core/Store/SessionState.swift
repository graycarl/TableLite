import Foundation

/// `session.json` 的内容。
///
/// 决策见 `05-session-management.md` §8：**启动不恢复会话**，文件只记「按连接的标签现场」
/// （每个连接的库 / 活动标签，以及每个标签的显示条数、排序、过滤、隐藏列等），
/// 用户连上该连接时才套用（S36）。
///
/// 版本与向前兼容规则见 `02-persistence.md` §9：未知字段忽略、缺失字段取默认值。
public struct SessionStateFile: Sendable, Codable, Equatable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// 本次运行的活动连接。仅供记录，不驱动启动行为（S36）。
    public var activeConnectionID: UUID?
    /// 每个连接上次的标签现场。
    public var sessions: [SessionState]

    public init(
        schemaVersion: Int = SessionStateFile.currentSchemaVersion,
        activeConnectionID: UUID? = nil,
        sessions: [SessionState] = []
    ) {
        self.schemaVersion = schemaVersion
        self.activeConnectionID = activeConnectionID
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeConnectionID
        case sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        activeConnectionID = try container.decodeIfPresent(UUID.self, forKey: .activeConnectionID)
        sessions = try container.decodeIfPresent([SessionState].self, forKey: .sessions) ?? []
    }
}

/// 一个连接的会话状态。
public struct SessionState: Sendable, Codable, Equatable, Identifiable {

    public var connectionID: UUID
    /// 当前选中的库。
    public var selectedDatabase: String?
    /// 当前活动标签。
    public var activeTabID: UUID?
    public var tabs: [SessionTabState]

    public var id: UUID { connectionID }

    public init(
        connectionID: UUID,
        selectedDatabase: String? = nil,
        activeTabID: UUID? = nil,
        tabs: [SessionTabState] = []
    ) {
        self.connectionID = connectionID
        self.selectedDatabase = selectedDatabase
        self.activeTabID = activeTabID
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey {
        case connectionID
        case selectedDatabase
        case activeTabID
        case tabs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionID = try container.decode(UUID.self, forKey: .connectionID)
        selectedDatabase = try container.decodeIfPresent(String.self, forKey: .selectedDatabase)
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        tabs = try container.decodeIfPresent([SessionTabState].self, forKey: .tabs) ?? []
    }
}

/// 标签种类（`06-ui-layer.md` §3）。
public enum SessionTabKind: String, Sendable, Codable, CaseIterable {
    case tableData
    case tableStructure
    case objectDefinition
    case query
    case history
    case consoleLog
}

/// 单个标签的恢复状态。字段都有默认值，方便向前兼容读取。
public struct SessionTabState: Sendable, Codable, Equatable, Identifiable {

    public var id: UUID
    public var kind: SessionTabKind
    public var title: String
    public var database: String?
    /// 表名 / 视图名 / 对象名。
    public var objectName: String?
    /// 查询标签的草稿 id（`05-session-management.md` §9）。
    public var queryDraftID: UUID?
    /// 查询标签关联的磁盘文件（从文件打开或另存为过）。
    public var filePath: String?
    /// 表数据标签的显示条数状态（`session.json` 字段名沿用旧的 `page`）。
    public var rowLimit: RowLimitState?
    /// 排序。
    public var sort: [SortOrder]
    /// 隐藏列。
    public var hiddenColumns: [String]
    /// 过滤器。
    public var filter: FilterState?
    /// 滚动到第几行。
    public var scrollRow: Int?
    /// 焦点列名。
    public var focusedColumn: String?

    public init(
        id: UUID = UUID(),
        kind: SessionTabKind,
        title: String = "",
        database: String? = nil,
        objectName: String? = nil,
        queryDraftID: UUID? = nil,
        filePath: String? = nil,
        rowLimit: RowLimitState? = nil,
        sort: [SortOrder] = [],
        hiddenColumns: [String] = [],
        filter: FilterState? = nil,
        scrollRow: Int? = nil,
        focusedColumn: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.database = database
        self.objectName = objectName
        self.queryDraftID = queryDraftID
        self.filePath = filePath
        self.rowLimit = rowLimit
        self.sort = sort
        self.hiddenColumns = hiddenColumns
        self.filter = filter
        self.scrollRow = scrollRow
        self.focusedColumn = focusedColumn
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case database
        case objectName
        case queryDraftID
        case filePath
        case rowLimit = "page"
        case sort
        case hiddenColumns
        case filter
        case scrollRow
        case focusedColumn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(SessionTabKind.self, forKey: .kind) ?? .query
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        database = try container.decodeIfPresent(String.self, forKey: .database)
        objectName = try container.decodeIfPresent(String.self, forKey: .objectName)
        queryDraftID = try container.decodeIfPresent(UUID.self, forKey: .queryDraftID)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        rowLimit = try container.decodeIfPresent(RowLimitState.self, forKey: .rowLimit)
        sort = try container.decodeIfPresent([SortOrder].self, forKey: .sort) ?? []
        hiddenColumns = try container.decodeIfPresent([String].self, forKey: .hiddenColumns) ?? []
        filter = try container.decodeIfPresent(FilterState.self, forKey: .filter)
        scrollRow = try container.decodeIfPresent(Int.self, forKey: .scrollRow)
        focusedColumn = try container.decodeIfPresent(String.self, forKey: .focusedColumn)
    }
}
