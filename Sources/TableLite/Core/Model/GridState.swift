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

// MARK: - 分页

/// 每页行数的可选档位与上限。见 `specs/03-data-browsing.md` §2。
public enum PageSize {
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

/// 分页状态。页码从 0 开始。
public struct PageState: Sendable, Codable, Equatable, Hashable {
    public var pageIndex: Int
    public var pageSize: Int
    public var rowCount: RowCountEstimate?

    public init(pageIndex: Int = 0, pageSize: Int = PageSize.default, rowCount: RowCountEstimate? = nil) {
        self.pageIndex = max(0, pageIndex)
        self.pageSize = PageSize.isValid(pageSize) ? pageSize : PageSize.default
        self.rowCount = rowCount
    }

    /// 查询用的 `OFFSET`。
    public var offset: Int { pageIndex * pageSize }

    /// 从 `pageSize + 1` 行的查询结果判断是否有下一页（多出的一行不显示）。
    public func hasNextPage(fetchedRowCount: Int) -> Bool {
        fetchedRowCount > pageSize
    }

    /// 实际展示的行数（去掉用于探测下一页的那一行）。
    public func visibleRowCount(fetchedRowCount: Int) -> Int {
        min(fetchedRowCount, pageSize)
    }

    /// 加深分页提示的阈值（偏移超过 10 万行）。
    public var isDeepOffset: Bool { offset > 100_000 }

    /// 状态栏文案：`行 1–300 / 约 12,480 行 · 第 1 页 · 300 行/页`。
    public func statusText(visibleCount: Int) -> String {
        let first = visibleCount == 0 ? 0 : offset + 1
        let last = offset + visibleCount
        let total = rowCount?.displayText ?? "行数未知"
        return "行 \(first)–\(last) / \(total) · 第 \(pageIndex + 1) 页 · \(pageSize) 行/页"
    }

    /// 过滤器 / 排序变化后重置到第 1 页。
    public mutating func resetToFirstPage() {
        pageIndex = 0
    }

    public mutating func goToNextPage() {
        pageIndex += 1
    }

    public mutating func goToPreviousPage() {
        pageIndex = max(0, pageIndex - 1)
    }

    /// 相对估算行数的总页数；估算不可靠时为 nil。
    public var pageCount: Int? {
        guard let rowCount, rowCount.isReliable, pageSize > 0 else { return nil }
        return Int((rowCount.approximate + Int64(pageSize) - 1) / Int64(pageSize))
    }
}
