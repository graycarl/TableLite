import Foundation

// MARK: - 行过滤器模型
//
// 见 docs/tech-designs/09-filtering.md 与 specs/05-filtering.md。
// 这里只有状态模型；SQL 生成在 Core/SQL（纯函数）。

enum FilterOperator: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case equal
    case notEqual
    case contains
    case notContains
    case beginsWith
    case endsWith
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    case between
    case inList
    case isNull
    case isNotNull

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .equal: return "等于"
        case .notEqual: return "不等于"
        case .contains: return "包含"
        case .notContains: return "不包含"
        case .beginsWith: return "开头是"
        case .endsWith: return "结尾是"
        case .greaterThan: return "大于"
        case .greaterThanOrEqual: return "大于等于"
        case .lessThan: return "小于"
        case .lessThanOrEqual: return "小于等于"
        case .between: return "在区间内"
        case .inList: return "在列表中"
        case .isNull: return "为空"
        case .isNotNull: return "不为空"
        }
    }

    /// 需要输入值
    var requiresValue: Bool {
        switch self {
        case .isNull, .isNotNull: return false
        default: return true
        }
    }

    /// 需要第二个值（区间）
    var requiresSecondValue: Bool { self == .between }
}

struct FilterCondition: Identifiable, Hashable, Sendable, Codable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var column: String = ""
    var op: FilterOperator = .equal
    var value: String = ""
    var secondValue: String = ""
}

enum FilterLogic: String, Hashable, Sendable, Codable, CaseIterable {
    case all
    case any

    var displayName: String {
        switch self {
        case .all: return "全部满足"
        case .any: return "满足任一"
        }
    }
}

/// 一个表数据标签的过滤状态。
struct FilterSet: Hashable, Sendable, Codable {
    var conditions: [FilterCondition] = []
    var logic: FilterLogic = .all
    /// 高级模式：原始 WHERE 片段
    var rawSQL: String = ""
    var useRawSQL: Bool = false

    var isEmpty: Bool {
        if useRawSQL { return rawSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return activeConditions.isEmpty
    }

    var activeConditions: [FilterCondition] {
        conditions.filter { $0.enabled && !$0.column.isEmpty }
    }
}

// MARK: - 排序 / 分页

struct SortDescriptor: Hashable, Sendable, Codable {
    var column: String
    var descending: Bool
}

struct TablePageRequest: Hashable, Sendable {
    var schema: String
    var table: String
    /// 0-based
    var pageIndex: Int
    var pageSize: Int
    var sort: [SortDescriptor]
    var filter: FilterSet
}

// MARK: - 列显隐 / 列宽（按表记忆）

struct TablePresentationState: Hashable, Sendable, Codable {
    var hiddenColumns: Set<String> = []
    /// 列名 → 宽度（pt）
    var columnWidths: [String: Double] = [:]
    var filter: FilterSet = FilterSet()
    var sort: [SortDescriptor] = []
    var pageSize: Int?
}
