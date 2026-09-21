import Foundation

// MARK: - 标签种类

/// 标签种类。见 `specs/02-workspace.md` §6、`docs/tech-designs/06-ui-layer.md` §3。
///
/// 去重规则全部抽在这里的纯函数上（`isReusable` / `matches` / `existingTab`），
/// 便于单元测试覆盖，`ConnectionSession` 只负责调用。
enum TabKind: Hashable, Sendable {
    case tableData(TableRef)
    case tableStructure(TableRef)
    case objectDefinition(TableRef, DatabaseObjectKind)
    /// `UUID` 是该查询标签的 draftID（草稿文件名）。
    case query(UUID)
    case history
    case consoleLog
}

extension TabKind {

    /// 是否对「同类同目标」的重复打开做复用。
    ///
    /// - 查询标签**总是新建**（每次 `⌘T` / 新建查询都是新标签）；
    /// - 表数据 / 表结构 / 对象定义按 schema + 名称精确匹配复用；
    /// - 历史 / Console Log 各只允许一个。
    ///
    /// 外键跳转要求「即使目标表已打开也新建」，这不是去重规则本身，而是调用方
    /// 用 `forceNew: true` 显式跳过复用（见 `ConnectionSession.openTableData(_:forceNew:)`）。
    var isReusable: Bool {
        switch self {
        case .tableData, .tableStructure, .objectDefinition, .history, .consoleLog:
            return true
        case .query:
            return false
        }
    }

    /// 两个可复用标签是否指向同一个目标。任一方是查询标签时恒为 false。
    func matches(_ other: TabKind) -> Bool {
        guard isReusable, other.isReusable else { return false }
        switch (self, other) {
        case let (.tableData(lhs), .tableData(rhs)):
            return lhs == rhs
        case let (.tableStructure(lhs), .tableStructure(rhs)):
            return lhs == rhs
        case let (.objectDefinition(lhsRef, lhsKind), .objectDefinition(rhsRef, rhsKind)):
            return lhsRef == rhsRef && lhsKind == rhsKind
        case (.history, .history):
            return true
        case (.consoleLog, .consoleLog):
            return true
        default:
            return false
        }
    }

    /// 在已有标签里查找可复用的下标。查询标签恒返回 `nil`（总是新建）。
    static func existingTab(for kind: TabKind, in tabs: [TabKind]) -> Int? {
        guard kind.isReusable else { return nil }
        return tabs.firstIndex { $0.matches(kind) }
    }

    /// 查询标签的草稿 id；其余标签为 nil。
    var draftID: UUID? {
        if case .query(let id) = self { return id }
        return nil
    }
}

// MARK: - 标签

/// 一个工作区标签。
///
/// 标签只持有「身份 + 展示状态」，具体内容由 Wave 4/5 的 ViewModel 装配
/// （`docs/tech-designs/06-ui-layer.md` §2：每个标签的 ViewModel 由标签自己持有）。
///
/// ⚠️ 为避免与并行开发的 ViewModel 编译耦合，下面的内容属性声明为 `AnyObject?`；
/// 装配时由 ViewModel 设置，使用方按具体类型强转：
///   - `tableData`        → `TableDataViewModel`
///   - `tableStructure`   → `TableStructureViewModel`
///   - `objectDefinition` → `ObjectDefinitionViewModel`
///   - `query`            → `QueryTabViewModel`
@MainActor
final class Tab: ObservableObject, Identifiable {

    let id = UUID()
    let kind: TabKind

    /// 查询标签的编号（1-based），用于默认标题「查询 N」。
    let queryNumber: Int

    /// 右键重命名后的标题。为空时回落到按 `kind` 计算的默认标题。
    @Published var customTitle: String?

    /// 结构视图「可能过期」（例如执行 DDL 后、重连后）。
    @Published var isStale: Bool

    /// 是否有未提交改动。关闭 / 退出时据此弹确认（`specs/02-workspace.md` §6）。
    @Published var hasPendingChanges: Bool

    /// 由 Wave 4/5 装配的具体 ViewModel。
    var tableData: AnyObject?
    var tableStructure: AnyObject?
    var objectDefinition: AnyObject?
    var query: AnyObject?

    /// 查询标签新建时携带的初始 SQL（例如「打开脚本…」）。ViewModel 装配时读取。
    var initialSQL: String?

    /// 重连后由 `ConnectionSession` 调用，刷新该标签的数据。Wave 4/5 装配时设置。
    var reloadAfterReconnect: (@MainActor () async -> Void)?

    init(kind: TabKind, queryNumber: Int = 0, isStale: Bool = false, hasPendingChanges: Bool = false) {
        self.kind = kind
        self.queryNumber = queryNumber
        self.isStale = isStale
        self.hasPendingChanges = hasPendingChanges
    }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        switch kind {
        case .tableData(let ref):
            return ref.table
        case .tableStructure(let ref):
            return "\(ref.table) · 结构"
        case .objectDefinition(let ref, _):
            return ref.table
        case .query:
            return queryNumber > 0 ? "查询 \(queryNumber)" : "查询"
        case .history:
            return "查询历史"
        case .consoleLog:
            return "Console Log"
        }
    }
}
