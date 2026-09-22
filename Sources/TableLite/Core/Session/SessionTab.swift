import Foundation
import Observation

// MARK: - 标签种类

/// 标签种类与去重规则（`docs/tech-designs/06-ui-layer.md` §3、`specs/02-workspace.md` §6）。
///
/// 去重规则抽成纯函数（`isReusable` / `matches` / `existingIndex`），便于单测；
/// `ConnectionSession` 只负责调用。
public enum TabKind: Sendable, Hashable {

    case tableData(database: String, table: String)
    case tableStructure(database: String, table: String)
    /// 对象定义（视图定义语句，只读）。
    case objectDefinition(database: String, object: String)
    /// 查询标签；`draftID` 是草稿文件名（`05-session-management.md` §9）。
    case query(draftID: UUID)
    case history
    case consoleLog

    // MARK: 持久化映射

    public var sessionKind: SessionTabKind {
        switch self {
        case .tableData: return .tableData
        case .tableStructure: return .tableStructure
        case .objectDefinition: return .objectDefinition
        case .query: return .query
        case .history: return .history
        case .consoleLog: return .consoleLog
        }
    }

    public var database: String? {
        switch self {
        case .tableData(let database, _),
             .tableStructure(let database, _),
             .objectDefinition(let database, _):
            return database
        case .query, .history, .consoleLog:
            return nil
        }
    }

    public var objectName: String? {
        switch self {
        case .tableData(_, let table), .tableStructure(_, let table):
            return table
        case .objectDefinition(_, let object):
            return object
        case .query, .history, .consoleLog:
            return nil
        }
    }

    /// 查询标签的草稿 id。
    public var draftID: UUID? {
        if case .query(let draftID) = self { return draftID }
        return nil
    }

    public var isQuery: Bool {
        if case .query = self { return true }
        return false
    }

    public var isTableData: Bool {
        if case .tableData = self { return true }
        return false
    }

    /// 从 `session.json` 的标签状态还原种类。
    public init?(sessionState state: SessionTabState) {
        switch state.kind {
        case .tableData:
            guard let database = state.database, let name = state.objectName else { return nil }
            self = .tableData(database: database, table: name)
        case .tableStructure:
            guard let database = state.database, let name = state.objectName else { return nil }
            self = .tableStructure(database: database, table: name)
        case .objectDefinition:
            guard let database = state.database, let name = state.objectName else { return nil }
            self = .objectDefinition(database: database, object: name)
        case .query:
            guard let draftID = state.queryDraftID else { return nil }
            self = .query(draftID: draftID)
        case .history:
            self = .history
        case .consoleLog:
            self = .consoleLog
        }
    }

    // MARK: 去重

    /// 是否对「同类同目标」的重复打开做复用。
    ///
    /// - 查询标签**总是新建**；
    /// - 表数据 / 表结构 / 对象定义按 schema + 名称精确匹配复用；
    /// - 历史 / Console Log 各只允许一个。
    public var isReusable: Bool {
        switch self {
        case .query: return false
        case .tableData, .tableStructure, .objectDefinition, .history, .consoleLog: return true
        }
    }

    /// 两个可复用标签是否指向同一个目标。
    public func matches(_ other: TabKind) -> Bool {
        guard isReusable, other.isReusable else { return false }
        switch (self, other) {
        case let (.tableData(lhsDB, lhsTable), .tableData(rhsDB, rhsTable)):
            return lhsDB == rhsDB && lhsTable == rhsTable
        case let (.tableStructure(lhsDB, lhsTable), .tableStructure(rhsDB, rhsTable)):
            return lhsDB == rhsDB && lhsTable == rhsTable
        case let (.objectDefinition(lhsDB, lhsObject), .objectDefinition(rhsDB, rhsObject)):
            return lhsDB == rhsDB && lhsObject == rhsObject
        case (.history, .history), (.consoleLog, .consoleLog):
            return true
        default:
            return false
        }
    }

    /// 在已有标签里查找可复用的下标；查询标签恒返回 nil。
    public static func existingIndex(for kind: TabKind, in kinds: [TabKind]) -> Int? {
        guard kind.isReusable else { return nil }
        return kinds.firstIndex { $0.matches(kind) }
    }
}

// MARK: - 标签

/// 一个工作区标签。
///
/// 只持有「身份 + 展示状态 + 内容视图挂载点」；具体内容视图与 ViewModel 由后续 Wave 装配
/// （`06-ui-layer.md` §2：每个标签的 ViewModel 由标签自己持有）。
///
/// 分页 / 排序 / 过滤 / 隐藏列等状态使 `session.json` 的 `SessionTabState` 能往返
/// （`05-session-management.md` §8）。
@MainActor
@Observable
public final class Tab: Identifiable {

    public let id: UUID
    public let kind: TabKind

    /// 查询标签的编号（1-based），用于默认标题「查询 N」。
    public let queryNumber: Int

    /// 右键重命名后的标题；为空时回落到默认标题。
    public var customTitle: String?

    /// 结构视图「可能过期」（执行 DDL 或重连后）。
    public var isStale: Bool

    /// 是否有未提交改动。关闭标签 / 退出 App 时据此弹确认。
    public var hasPendingChanges: Bool

    // MARK: 表数据标签状态

    public var page: PageState
    public var sort: [SortOrder]
    public var hiddenColumns: [String]
    public var filter: FilterState?
    public var scrollRow: Int?
    public var focusedColumn: String?

    /// 外键 `↗` 跳转带入的初始过滤条件；不随 `session.json` 往返。
    /// 装配 `TableDataViewModel` 时优先于「按表记住的过滤」。
    @ObservationIgnored public var initialFilter: FilterState?

    // MARK: 查询标签状态

    /// 关联的磁盘文件（从文件打开或另存为过）。
    public var filePath: String?
    /// 「打开脚本…」带入的初始内容，由 ViewModel 装配时读取。
    public var initialSQL: String?

    // MARK: 内容视图挂载点（后续 Wave 填充）

    /// 具体内容视图 / ViewModel。为避免与并行开发耦合，声明为 `AnyObject?`。
    ///
    /// **可观察**：`WorkspaceView` 的右侧字段栏按 `activeTab.content as? TableDataViewModel`
    /// 取网格的选区投影，必须能在内容装配后重绘（T8 起）。
    public var content: AnyObject?
    /// 重连后刷新该标签的数据；由内容视图装配时设置。
    @ObservationIgnored public var reloadAfterReconnect: (@MainActor () async -> Void)?

    public init(id: UUID = UUID(), kind: TabKind, queryNumber: Int = 0, isStale: Bool = false, hasPendingChanges: Bool = false) {
        self.id = id
        self.kind = kind
        self.queryNumber = queryNumber
        self.isStale = isStale
        self.hasPendingChanges = hasPendingChanges
        self.page = PageState()
        self.sort = []
        self.hiddenColumns = []
        self.filter = nil
        self.scrollRow = nil
        self.focusedColumn = nil
        self.filePath = nil
        self.initialSQL = nil
        self.initialFilter = nil
    }

    /// 标签标题。
    public var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        switch kind {
        case .tableData(_, let table):
            return table
        case .tableStructure(_, let table):
            return "\(table) · 结构"
        case .objectDefinition(_, let object):
            return object
        case .query:
            return queryNumber > 0 ? "查询 \(queryNumber)" : "查询"
        case .history:
            return "查询历史"
        case .consoleLog:
            return "Console Log"
        }
    }

    // MARK: 持久化

    /// 导出为 `session.json` 的标签状态。
    public func snapshot() -> SessionTabState {
        SessionTabState(
            id: id,
            kind: kind.sessionKind,
            title: title,
            database: kind.database,
            objectName: kind.objectName,
            queryDraftID: kind.draftID,
            filePath: filePath,
            page: kind.isTableData ? page : nil,
            sort: sort,
            hiddenColumns: hiddenColumns,
            filter: filter,
            scrollRow: scrollRow,
            focusedColumn: focusedColumn
        )
    }

    /// 从 `session.json` 恢复标签骨架。
    ///
    /// 不自动连接；结构 / 对象定义标签标为「可能过期」，连接后由 `⌘R` 或刷新入口重取。
    public convenience init?(state: SessionTabState) {
        guard let kind = TabKind(sessionState: state) else { return nil }
        let isStale: Bool
        switch kind {
        case .tableStructure, .objectDefinition:
            isStale = true
        default:
            isStale = false
        }
        self.init(id: state.id, kind: kind, queryNumber: 0, isStale: isStale)
        if !state.title.isEmpty, state.title != title {
            customTitle = state.title
        }
        filePath = state.filePath
        page = state.page ?? PageState()
        sort = state.sort
        hiddenColumns = state.hiddenColumns
        filter = state.filter
        scrollRow = state.scrollRow
        focusedColumn = state.focusedColumn
    }
}
