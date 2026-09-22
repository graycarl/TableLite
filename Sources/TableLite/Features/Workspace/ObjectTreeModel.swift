import Foundation

/// 对象树的两个分组（`specs/02-workspace.md` §5）。
///
/// 需求只保留表与视图两组（S17）。这里抽成纯类型，便于单测分组与计数逻辑。
enum ObjectTreeGroup: String, CaseIterable, Identifiable, Sendable {
    case table
    case view

    var id: String { rawValue }

    var kind: TableKind {
        switch self {
        case .table: return .table
        case .view: return .view
        }
    }

    var title: String {
        switch self {
        case .table: return "表"
        case .view: return "视图"
        }
    }

    init(kind: TableKind) {
        switch kind {
        case .table: self = .table
        case .view: self = .view
        }
    }
}

/// 一个分组在界面上的内容快照。
///
/// 由 `ObjectTreeModel.group(...)` 纯函数计算，视图只负责渲染。
struct ObjectTreeGroupContent: Equatable, Identifiable {
    let group: ObjectTreeGroup
    /// 过滤 + 截断后要显示的对象。
    let items: [TableInfo]
    /// 未过滤时该组的对象总数。
    let total: Int
    /// 命中当前过滤条件的对象数。
    let matched: Int
    /// 命中数是否超过显示上限（需要显示「仅显示前 N 项」提示）。
    let isTruncated: Bool
    /// 当前是否处于搜索过滤状态。
    let isFiltering: Bool

    var id: String { group.rawValue }

    var isEmpty: Bool { items.isEmpty }

    /// 标题里显示的数量：搜索时显示命中数，否则显示总数。
    var count: Int { isFiltering ? matched : total }

    /// 分组标题，如「表 (128)」。
    var title: String { "\(group.title) (\(count))" }
}

/// 对象树的过滤 / 分组纯逻辑。
///
/// 规则见 `specs/02-workspace.md` §5：
/// - 搜索大小写不敏感、子串匹配，输入即过滤；
/// - 搜索时只显示命中的对象（分组由视图自动展开）；
/// - 单个分组超过 500 项时只显示前 500 项，并给出提示。
enum ObjectTreeModel {

    /// 单个分组一次最多渲染的对象数。
    static let displayLimit = 500

    /// 「仅显示前 N 项」提示文案。
    static var truncationHint: String { "仅显示前 \(displayLimit) 项，请用上方搜索框查找" }

    /// 大小写不敏感的子串过滤。
    static func filtered(_ objects: [TableInfo], query: String) -> [TableInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return objects }
        return objects.filter { $0.name.range(of: trimmed, options: .caseInsensitive) != nil }
    }

    /// 按分组类型拆成「表 / 视图」两组，并应用搜索过滤与显示上限。
    static func group(
        _ objects: [TableInfo],
        query: String = "",
        limit: Int = displayLimit
    ) -> [ObjectTreeGroupContent] {
        let isFiltering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let matched = filtered(objects, query: query)
        return ObjectTreeGroup.allCases.map { group in
            let all = objects.filter { $0.kind == group.kind }
            let hits = matched.filter { $0.kind == group.kind }
            return ObjectTreeGroupContent(
                group: group,
                items: Array(hits.prefix(limit)),
                total: all.count,
                matched: hits.count,
                isTruncated: hits.count > limit,
                isFiltering: isFiltering
            )
        }
    }
}
