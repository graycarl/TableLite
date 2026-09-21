import Combine
import Foundation

// MARK: - 对象树分组

/// 对象树里的一个分组（表 / 视图）。见 `specs/02-workspace.md` §5。
struct ObjectTreeSection: Identifiable, Hashable, Sendable {
    let kind: DatabaseObjectKind
    /// 过滤 + 截断之后要展示的对象。
    var objects: [DatabaseObject]
    /// 分组标题里的数量：搜索时为命中数，否则为该分组的全部对象数。
    var totalCount: Int
    /// 是否因展示上限被截断（`specs/02-workspace.md` §5，表 500 个）。
    var isTruncated: Bool

    var id: String { kind.rawValue }
    var title: String { kind == .table ? "表" : "视图" }
}

// MARK: - ObjectTreeModel

/// 对象树的展示模型：搜索过滤、按表 / 视图分组、500 项截断、分组折叠状态。
///
/// 只做「对象数组 → 分组」的纯逻辑；数据来源是 `ConnectionSession.objects`
///（`selectDatabase` 变化时由 `ConnectionSession.refreshObjects()` 重新拉取）。
///
/// Wave 4 的对象树视图订阅本对象，读 `sections` 渲染、把点击转成
/// `ConnectionSession.openTableData/…` 意图。
@MainActor
final class ObjectTreeModel: ObservableObject {

    /// 单组（表）最多展示多少项。见 `specs/02-workspace.md` §5。
    static let displayLimit = 500

    /// 搜索文本。输入即过滤，大小写不敏感、子串匹配。
    @Published var searchText = ""

    /// 展开的分组。默认两组都展开。
    @Published var expandedGroups: Set<DatabaseObjectKind> = [.table, .view]

    /// 当前展示的库名（未选择库时为 nil）。
    @Published private(set) var database: String?

    /// `ConnectionSession` 传进来的原始对象列表（未过滤）。
    @Published private(set) var objects: [DatabaseObject] = []

    // MARK: 更新

    func update(objects: [DatabaseObject], database: String?) {
        self.objects = objects
        self.database = database
    }

    func clear() {
        objects = []
        database = nil
        searchText = ""
    }

    // MARK: 派生状态

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 库里一个对象都没有（区别于「搜索无命中」）。
    var isEmpty: Bool { objects.isEmpty }

    /// 有对象但搜索没有命中。
    var hasNoMatches: Bool { !objects.isEmpty && sections.allSatisfy { $0.objects.isEmpty } }

    /// 是否应显示「仅显示前 500 项」提示。
    var isTruncated: Bool { sections.contains { $0.isTruncated } }

    var sections: [ObjectTreeSection] {
        Self.sections(from: objects, search: searchText, limit: Self.displayLimit)
    }

    // MARK: 纯逻辑

    /// 按名字过滤：大小写不敏感的子串匹配；空搜索返回全部。
    static func filtered(_ objects: [DatabaseObject], search: String) -> [DatabaseObject] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return objects }
        return objects.filter { $0.name.lowercased().contains(keyword) }
    }

    /// 过滤 → 分组 → 截断。表组受 `limit` 限制，视图组不限制。
    static func sections(from objects: [DatabaseObject],
                         search: String,
                         limit: Int) -> [ObjectTreeSection] {
        let matched = filtered(objects, search: search)
        return [DatabaseObjectKind.table, .view].map { kind in
            let group = matched.filter { $0.kind == kind }
            let capped = (kind == .table) ? Array(group.prefix(max(0, limit))) : group
            return ObjectTreeSection(kind: kind,
                                     objects: capped,
                                     totalCount: group.count,
                                     isTruncated: capped.count < group.count)
        }
    }
}
