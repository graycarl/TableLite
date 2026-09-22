import Foundation
import Observation

/// 一条已执行（或被拦截）的语句的结果，对应结果区的一个标签。
///
/// 见 `specs/06-query-editor.md` §3/§4、`docs/tech-designs/10-query-editor.md` §6。
/// 每条语句一个标签：查询结果 / 影响行数 / 失败 / 只读拦截。
@MainActor
@Observable
final class QueryResultTab: Identifiable {

    enum Kind: Equatable {
        /// 有返回行的查询。
        case resultSet
        /// 非查询语句（影响行数 + `last_insert_id`）。
        case affected
        /// 执行失败。
        case failure
        /// 只读模式拦截。
        case blocked
    }

    let id = UUID()
    /// 语句在本次执行里的序号（1-based），用于「结果 N」。
    let ordinal: Int
    let statementText: String
    let statementKind: SQLStatementKind
    private(set) var kind: Kind

    // 结果集
    private(set) var columns: [ColumnInfo] = []
    private(set) var rows: [[SQLValue]] = []
    /// 结果集行数（可能超过内存里保留的行；当前等于 `rows.count`）。
    private(set) var returnedRowCount = 0
    /// 结果是否过大（L1 提示）。
    private(set) var isLarge = false

    // 非查询
    private(set) var affectedRows: Int64 = 0
    private(set) var lastInsertID: UInt64 = 0

    // 通用
    private(set) var durationMilliseconds = 0
    private(set) var error: MySQLError?
    /// 触发大结果提示的行数阈值（10 万行，`specs/06-query-editor.md` §3）。
    static let largeRowThreshold = 100_000

    init(ordinal: Int, statement: SQLStatement) {
        self.ordinal = ordinal
        self.statementText = statement.text
        self.statementKind = statement.kind
        self.kind = .affected
    }

    // MARK: 构造

    func apply(result: MySQLQueryResult, durationMilliseconds: Int) {
        self.durationMilliseconds = durationMilliseconds
        if let error = result.firstError {
            self.error = error
            self.kind = .failure
            return
        }
        if let set = result.firstResultSet {
            columns = set.header.columns
            rows = set.rows.map { $0.values(columns: set.header.columns) }
            returnedRowCount = rows.count
            isLarge = rows.count > Self.largeRowThreshold
            kind = .resultSet
        } else {
            affectedRows = result.affectedRows
            lastInsertID = result.lastInsertID
            kind = .affected
        }
    }

    func markBlocked(reason: String) {
        kind = .blocked
        error = nil
        blockedReason = reason
    }

    func markFailure(_ error: MySQLError, durationMilliseconds: Int) {
        self.error = error
        self.durationMilliseconds = durationMilliseconds
        kind = .failure
    }

    private(set) var blockedReason: String?

    // MARK: 展示

    var title: String {
        switch kind {
        case .resultSet: return "结果 \(ordinal)"
        case .affected: return "完成"
        case .failure: return "错误"
        case .blocked: return "只读拦截"
        }
    }

    var symbolName: String {
        switch kind {
        case .resultSet: return "tablecells"
        case .affected: return "checkmark.circle"
        case .failure: return "exclamationmark.triangle"
        case .blocked: return "lock"
        }
    }

    /// 标签是否标红（出错 / 被拦截）。
    var isFailure: Bool {
        kind == .failure || kind == .blocked
    }

    /// 「共 N 条 · 耗时 X ms」里的结果集数量（由视图统计）。
    var affectedSummary: String {
        var parts = ["影响 \(affectedRows) 行"]
        if lastInsertID != 0 {
            parts.append("last_insert_id = \(lastInsertID)")
        }
        if durationMilliseconds > 0 {
            parts.append("耗时 \(durationMilliseconds) ms")
        }
        return parts.joined(separator: " · ")
    }

    var emptyResultText: String {
        "查询成功，0 行，耗时 \(durationMilliseconds) ms"
    }
}
