import Foundation

// MARK: - 导出源

/// 导出的数据来源。对应 `specs/08-import-export.md` §1「入口」的四种入口。
///
/// 入口视图只接收本枚举，具体的 SQL 生成由 `ExportQueryPlanner` 完成。
public enum ExportSource: Sendable, Equatable {
    /// 对象树右键表 →「导出…」：整张表，不受过滤条件影响。
    case table(database: String, table: String)
    /// 数据视图状态栏「导出…」：当前过滤条件下的全部数据（不是当前页）。
    case filteredTable(database: String, table: String, filterClause: String, filterSummary: String)
    /// 查询结果标签右键「导出结果…」：该结果集的全部行。
    case queryResult(sql: String, description: String)
    /// 右键选中行「导出选中行…」：`whereClause` 是不带 `WHERE` 的定位条件。
    case selectedRows(database: String, table: String, whereClause: String, rowCount: Int)

    /// 面板顶部「源」的标题。
    public var title: String {
        switch self {
        case .table(let database, let table), .filteredTable(let database, let table, _, _):
            return "\(database).\(table)"
        case .selectedRows(let database, let table, _, _):
            return "\(database).\(table)（选中行）"
        case .queryResult(_, let description):
            return description
        }
    }

    public var database: String? {
        switch self {
        case .table(let database, _), .filteredTable(let database, _, _, _), .selectedRows(let database, _, _, _):
            return database
        case .queryResult:
            return nil
        }
    }

    /// 面板顶部「源」下那一行的说明。行数估算由调用方传入（`TableInfo.rowCountEstimate`）。
    public func detailText(rowCountEstimate: Int64?) -> String {
        let estimateText: String? = {
            guard let rowCountEstimate, rowCountEstimate >= 0 else { return nil }
            return "共约 \(Self.grouped(rowCountEstimate)) 行"
        }()
        switch self {
        case .table:
            return ["整张表（不受过滤条件影响）", estimateText].compactMap { $0 }.joined(separator: "，")
        case .filteredTable(_, _, _, let filterSummary):
            let filterPart = "应用了过滤条件：\(filterSummary)"
            return [filterPart, estimateText].compactMap { $0 }.joined(separator: "，")
        case .selectedRows(_, _, _, let rowCount):
            return "仅导出选中的 \(Self.grouped(Int64(rowCount))) 行"
        case .queryResult:
            return "该查询结果集的全部行"
        }
    }

    /// 目标文件默认名（保存面板建议名）。
    public var suggestedFileName: String {
        switch self {
        case .table(_, let table), .filteredTable(_, let table, _, _), .selectedRows(_, let table, _, _):
            return "\(table).csv"
        case .queryResult:
            return "query-result.csv"
        }
    }

    static func grouped(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
