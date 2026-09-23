import Foundation

// MARK: - 排序

public enum SortDirection: String, Sendable, Codable, CaseIterable, Hashable {
    case ascending
    case descending

    public var keyword: String {
        switch self {
        case .ascending: return "ASC"
        case .descending: return "DESC"
        }
    }

    public var arrow: String {
        switch self {
        case .ascending: return "▲"
        case .descending: return "▼"
        }
    }

    /// 点列头循环：升序 → 降序 → 无。
    public var next: SortDirection? {
        switch self {
        case .ascending: return .descending
        case .descending: return nil
        }
    }
}

/// 一列排序。
public struct SortOrder: Sendable, Codable, Equatable, Hashable {
    public var column: String
    public var direction: SortDirection

    public init(column: String, direction: SortDirection) {
        self.column = column
        self.direction = direction
    }
}

// MARK: - 显示条数

/// 一次加载最多取多少行：可选档位与上限。见 `specs/03-data-browsing.md` §2。
public enum RowLimit {
    public static let presets = [100, 300, 1000, 5000]
    public static let `default` = 300
    public static let maximum = 10000

    public static func isValid(_ size: Int) -> Bool {
        size >= 1 && size <= maximum
    }
}

/// 行数估算。`information_schema.TABLES` 的 `TABLE_ROWS` 对 InnoDB 只是估算。
public struct RowCountEstimate: Sendable, Codable, Equatable, Hashable {
    public var approximate: Int64
    /// 估算是否可靠；不可靠时界面显示「约 0 行（估算不可靠）」。
    public var isReliable: Bool
    /// 是否由用户点了「精确统计」得到。
    public var isExact: Bool

    public init(approximate: Int64, isReliable: Bool = true, isExact: Bool = false) {
        self.approximate = approximate
        self.isReliable = isReliable
        self.isExact = isExact
    }

    /// 状态栏文案，例如 `约 12,480 行` 或 `12,480 行`。
    public var displayText: String {
        let number = Self.grouped(approximate)
        if isExact { return "\(number) 行" }
        if !isReliable { return "约 0 行（估算不可靠）" }
        return "约 \(number) 行"
    }

    /// 给整数加千位分隔符。不用 `NumberFormatter`，避免共享可变状态。
    static func grouped(_ value: Int64) -> String {
        let isNegative = value < 0
        var digits = Array(String(isNegative ? -value : value))
        var grouped: [Character] = []
        var counter = 0
        while let digit = digits.popLast() {
            if counter > 0 && counter % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
            counter += 1
        }
        let text = String(grouped.reversed())
        return isNegative ? "-" + text : text
    }
}

/// 表数据「显示前 N 行」的状态。取消分页后不再有页码。
///
/// `session.json` 里内层字段名沿用旧的 `pageSize`，旧文件可直接读回。
public struct RowLimitState: Sendable, Codable, Equatable, Hashable {
    /// 最多显示多少行（`RowLimit.isValid` 之外的取值回落到默认值）。
    public var limit: Int
    public var rowCount: RowCountEstimate?

    public init(limit: Int = RowLimit.default, rowCount: RowCountEstimate? = nil) {
        self.limit = RowLimit.isValid(limit) ? limit : RowLimit.default
        self.rowCount = rowCount
    }

    /// 状态栏文案：`显示 300 行 / 约 12,480 行`。
    public func statusText(visibleCount: Int) -> String {
        let total = rowCount?.displayText ?? "行数未知"
        return "显示 \(visibleCount) 行 / \(total)"
    }

    private enum CodingKeys: String, CodingKey {
        case limit = "pageSize"
        case rowCount
    }
}
