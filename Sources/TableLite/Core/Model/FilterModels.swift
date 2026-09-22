import Foundation

/// 行过滤器的操作符。对应 `specs/05-filtering.md` §1「可用操作符」。
public enum FilterOperator: String, Sendable, Codable, CaseIterable, Hashable {
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

    /// 界面上显示的中文名。
    public var displayName: String {
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

    /// 是否需要值输入框。
    public var requiresValue: Bool {
        switch self {
        case .isNull, .isNotNull: return false
        default: return true
        }
    }

    /// 是否需要第二个值（仅「在区间内」）。
    public var requiresSecondValue: Bool {
        self == .between
    }

    /// `IN` 列表类操作符。
    public var isListOperator: Bool {
        self == .inList
    }
}

/// 条件组合方式：全部满足（AND）或满足任一（OR）。
public enum FilterCombination: String, Sendable, Codable, CaseIterable, Hashable {
    case all
    case any

    public var displayName: String {
        switch self {
        case .all: return "全部满足"
        case .any: return "满足任一"
        }
    }

    public var keyword: String {
        switch self {
        case .all: return "AND"
        case .any: return "OR"
        }
    }
}

/// 单条过滤条件。
public struct FilterCondition: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var isEnabled: Bool
    public var column: String
    public var op: FilterOperator
    /// 值文本；`between` 的第一个端点；`inList` 的逗号分隔列表。
    public var value: String
    /// `between` 的第二个端点。
    public var secondValue: String
    /// 目标列类型，用于决定数字字面量是否去引号；nil 时一律当字符串。
    public var fieldType: MySQLFieldType?
    public var isBinary: Bool

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        column: String,
        op: FilterOperator,
        value: String = "",
        secondValue: String = "",
        fieldType: MySQLFieldType? = nil,
        isBinary: Bool = false
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
        self.fieldType = fieldType
        self.isBinary = isBinary
    }

    /// 需要值但输入为空，应用时跳过并在界面标黄。
    public var isIncomplete: Bool {
        guard isEnabled, op.requiresValue else { return false }
        if op.requiresSecondValue {
            return value.trimmingCharacters(in: .whitespaces).isEmpty
                || secondValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// 行过滤器的完整状态。**纯客户端状态**，不改数据。
///
/// 见 `docs/tech-designs/09-filtering.md` §1.1。
public struct FilterState: Sendable, Codable, Equatable {
    public var conditions: [FilterCondition]
    public var combination: FilterCombination
    /// 高级模式：直接写 `WHERE` 片段。与 `conditions` 互斥。
    public var rawWhere: String
    public var isRawMode: Bool
    /// 过滤器横条是否可见（`Esc` 关闭但保留条件）。
    public var isVisible: Bool

    public init(
        conditions: [FilterCondition] = [],
        combination: FilterCombination = .all,
        rawWhere: String = "",
        isRawMode: Bool = false,
        isVisible: Bool = false
    ) {
        self.conditions = conditions
        self.combination = combination
        self.rawWhere = rawWhere
        self.isRawMode = isRawMode
        self.isVisible = isVisible
    }

    public static let empty = FilterState()

    // MARK: 向前兼容解码（`02-persistence.md` §9）

    private enum CodingKeys: String, CodingKey {
        case conditions, combination, rawWhere, isRawMode, isVisible
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conditions = try container.decodeIfPresent([FilterCondition].self, forKey: .conditions) ?? []
        combination = try container.decodeIfPresent(FilterCombination.self, forKey: .combination) ?? .all
        rawWhere = try container.decodeIfPresent(String.self, forKey: .rawWhere) ?? ""
        isRawMode = try container.decodeIfPresent(Bool.self, forKey: .isRawMode) ?? false
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
    }

    /// 启用且填写完整的条件。
    public var activeConditions: [FilterCondition] {
        isRawMode ? [] : conditions.filter { $0.isEnabled && !$0.isIncomplete }
    }

    /// 是否有任何会进入 `WHERE` 的内容。
    public var isActive: Bool {
        if isRawMode {
            return !rawWhere.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !activeConditions.isEmpty
    }

    /// 引用到的列名。
    public var referencedColumns: [String] {
        if isRawMode { return [] }
        return conditions.filter(\.isEnabled).map(\.column)
    }

    /// 切换到高级模式，清空条件行。
    public mutating func switchToRawMode() {
        isRawMode = true
        conditions.removeAll()
    }

    /// 切回条件行模式，清空原始片段。
    public mutating func switchToConditionsMode() {
        isRawMode = false
        rawWhere = ""
    }

    public mutating func reset() {
        conditions.removeAll()
        rawWhere = ""
    }

    /// 供右键「按此值筛选 / 排除此值」使用。
    public enum QuickFilterAction: Sendable, Equatable {
        case byColumn(column: String)
        case byValue(column: String, value: String)
        case excludeValue(column: String, value: String)
    }
}
