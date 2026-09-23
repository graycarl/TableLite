import Foundation

// MARK: - 导出源

/// 导出的数据来源。对应 `specs/08-import-export.md` §1「入口」的四种入口。
///
/// 入口视图只接收本枚举，具体的 SQL 生成由 `ExportQueryPlanner` 完成。
public enum ExportSource: Sendable, Equatable {
    /// 对象树右键表 →「导出…」：整张表，不受过滤条件影响。
    case table(database: String, table: String)
    /// 数据视图状态栏「导出…」：当前过滤条件下的全部数据（不是只加载的前 N 行）。
    ///
    /// `filterSummary` 是**真实**的过滤条件文本（取自 `FilterSQLBuilder` 生成的 `WHERE` 子句），
    /// `rowCountEstimate` 是当前过滤条件下界面已知的行数估算（来自显示条数栏的同一份估算）。
    case filteredTable(
        database: String,
        table: String,
        filterClause: String,
        filterSummary: String,
        rowCountEstimate: Int64?
    )
    /// 查询结果标签右键「导出结果…」：该结果集的全部行。
    case queryResult(sql: String, description: String)
    /// 右键选中行「导出选中行…」：`whereClause` 是不带 `WHERE` 的定位条件。
    case selectedRows(database: String, table: String, whereClause: String, rowCount: Int)

    /// 面板顶部「源」的标题。
    public var title: String {
        switch self {
        case .table(let database, let table), .filteredTable(let database, let table, _, _, _):
            return "\(database).\(table)"
        case .selectedRows(let database, let table, _, _):
            return "\(database).\(table)（选中行）"
        case .queryResult(_, let description):
            return description
        }
    }

    public var database: String? {
        switch self {
        case .table(let database, _), .filteredTable(let database, _, _, _, _), .selectedRows(let database, _, _, _):
            return database
        case .queryResult:
            return nil
        }
    }

    /// 面板顶部「源」下那一行的说明。行数估算由调用方传入（`TableInfo.rowCountEstimate`）。
    /// `filteredTable` 自带过滤条件下的估算，优先使用它。
    public func detailText(rowCountEstimate: Int64?) -> String {
        let effectiveEstimate = storedRowCountEstimate ?? rowCountEstimate
        let estimateText: String? = {
            guard let effectiveEstimate, effectiveEstimate >= 0 else { return nil }
            return "共约 \(Self.grouped(effectiveEstimate)) 行"
        }()
        switch self {
        case .table:
            return ["整张表（不受过滤条件影响）", estimateText].compactMap { $0 }.joined(separator: "，")
        case .filteredTable(_, _, _, let filterSummary, _):
            let filterPart = "应用了过滤条件：\(filterSummary)"
            return [filterPart, estimateText].compactMap { $0 }.joined(separator: "，")
        case .selectedRows(_, _, _, let rowCount):
            return "仅导出选中的 \(Self.grouped(Int64(rowCount))) 行"
        case .queryResult:
            return "该查询结果集的全部行"
        }
    }

    /// `filteredTable` 自带的过滤条件行数估算；其它来源为 nil。
    var storedRowCountEstimate: Int64? {
        if case .filteredTable(_, _, _, _, let estimate) = self { return estimate }
        return nil
    }

    /// 目标文件默认名（保存面板建议名）。
    public var suggestedFileName: String {
        switch self {
        case .table(_, let table), .filteredTable(_, let table, _, _, _), .selectedRows(_, let table, _, _):
            return "\(table).csv"
        case .queryResult:
            return "query-result.csv"
        }
    }

    static func grouped(_ value: Int64) -> String {
        RowCountEstimate.grouped(value)
    }
}

// MARK: - 日期格式

/// 导出时的日期格式（`specs/08-import-export.md` §1 面板）。默认原样输出。
public struct CSVDateFormat: Sendable, Equatable {
    public enum Style: String, Sendable, Equatable, Hashable, CaseIterable {
        case raw
        case custom

        public var displayName: String {
            switch self {
            case .raw: return "原样输出"
            case .custom: return "自定义"
            }
        }
    }

    public var style: Style
    /// `style == .custom` 时的 ICU 格式串（如 `yyyy-MM-dd HH:mm:ss`）。
    public var customPattern: String

    public init(style: Style = .raw, customPattern: String = CSVDateFormatter.defaultPattern) {
        self.style = style
        self.customPattern = customPattern
    }

    public static let raw = CSVDateFormat(style: .raw)

    /// 传给导出引擎的格式串；原样输出时为 nil。
    public var resolvedPattern: String? {
        guard style == .custom else { return nil }
        let trimmed = customPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 日期时间的自定义格式化。纯函数，供导出引擎与单测使用。
///
/// 只处理日期 / 日期时间列；无法解析时**原样返回**，宁可少转换也不要丢数据。
/// 解析与格式化固定用 UTC，保证「原样文本 → Date → 自定义格式」不因时区偏移改变日期分量。
public enum CSVDateFormatter {
    public static let defaultPattern = "yyyy-MM-dd HH:mm:ss"

    static func dateFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter
    }

    /// 把日期时间列的原样文本转成自定义格式。
    public static func formatted(_ value: SQLValue, column: ColumnInfo, pattern: String) -> SQLValue {
        guard !pattern.isEmpty, isFormattable(column), let text = value.textValue, !text.isEmpty else {
            return value
        }
        guard let date = parse(text) else { return value }
        return .text(dateFormatter(pattern).string(from: date))
    }

    /// 列类型是否参与自定义日期格式（DATE / DATETIME / TIMESTAMP / NEWDATE）。
    public static func isFormattable(_ column: ColumnInfo) -> Bool {
        switch column.fieldType {
        case .date, .newdate, .datetime, .timestamp: return true
        default: return false
        }
    }

    /// MySQL 日期时间原样文本 → `Date`。支持带小数秒的 DATETIME。
    public static func parse(_ text: String) -> Date? {
        let candidates = [
            text,
            text.split(separator: ".").first.map(String.init) ?? text,
        ]
        let patterns = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
        for candidate in candidates {
            for pattern in patterns {
                if let date = dateFormatter(pattern).date(from: candidate) { return date }
            }
        }
        return nil
    }
}

// MARK: - 导出格式

/// 导出格式。`specs/08-import-export.md` §3 明确只支持 CSV，
/// JSON / SQL INSERT 属于「明确不做」。这里保留枚举是为了让面板有一行
/// 「格式：CSV」的说明，将来若扩格式也只需加 case。
public enum ExportFormat: String, Sendable, CaseIterable {
    case csv

    public var displayName: String {
        switch self {
        case .csv: return "CSV"
        }
    }
}

// MARK: - 导出进度 / 结果

/// 导出过程中写入磁盘的统计快照。
public struct ExportProgress: Sendable, Equatable {
    public var rowCount: Int
    public var byteCount: Int

    public init(rowCount: Int, byteCount: Int) {
        self.rowCount = rowCount
        self.byteCount = byteCount
    }

    /// 面板 / 状态栏用的文案：`已写入 129,480 行（24.1 MB）`。
    public var displayText: String {
        "已写入 \(ExportSource.grouped(Int64(rowCount))) 行（\(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))）"
    }
}

/// 一次导出的最终结果。
public struct ExportSummary: Sendable, Equatable {
    public var rowCount: Int
    public var byteCount: Int
    /// 成功完成时的目标文件。
    public var destinationURL: URL?
    /// 取消 / 中断时保留的 `.partial` 文件。
    public var partialURL: URL?
    public var wasCancelled: Bool
    /// 失败原因（连接断开、磁盘错误等）。成功 / 取消时为 nil。
    public var failureMessage: String?

    public init(
        rowCount: Int,
        byteCount: Int,
        destinationURL: URL? = nil,
        partialURL: URL? = nil,
        wasCancelled: Bool = false,
        failureMessage: String? = nil
    ) {
        self.rowCount = rowCount
        self.byteCount = byteCount
        self.destinationURL = destinationURL
        self.partialURL = partialURL
        self.wasCancelled = wasCancelled
        self.failureMessage = failureMessage
    }

    public var isSuccess: Bool {
        failureMessage == nil && !wasCancelled
    }

    /// 通知文案：`导出完成：129,480 行 → articles.csv`。
    public var message: String {
        let file = destinationURL?.lastPathComponent ?? partialURL?.lastPathComponent ?? "文件"
        let rows = ExportSource.grouped(Int64(rowCount))
        if let failureMessage {
            return "导出中断，文件不完整（\(rows) 行）：\(failureMessage)"
        }
        if wasCancelled {
            return "导出已取消：已保留不完整的文件（\(rows) 行）"
        }
        return "导出完成：\(rows) 行 → \(file)"
    }
}

/// 导出面板的阶段。
public enum ExportPhase: Sendable, Equatable {
    case idle
    case preparing
    case running
    case done(ExportSummary)

    public var isRunning: Bool {
        switch self {
        case .preparing, .running: return true
        case .idle, .done: return false
        }
    }
}

// MARK: - 错误

/// CSV 流式写文件时的错误。
public enum CSVExportError: Error, Sendable, Equatable {
    /// 目标目录不可写 / 无法创建临时文件。
    case cannotCreateTempFile(String)
    case cannotOpenFile(String)
    case writeFailed(String)
    case replaceFailed(String)

    public var message: String {
        switch self {
        case .cannotCreateTempFile(let path): return "无法在目标目录创建临时文件：\(path)"
        case .cannotOpenFile(let path): return "无法打开目标文件：\(path)"
        case .writeFailed(let reason): return "写入失败：\(reason)"
        case .replaceFailed(let reason): return "保存文件失败：\(reason)"
        }
    }
}
