import Foundation

// MARK: - 变更暂存模型
//
// 核心机制见 docs/tech-designs/08-pending-changes.md。
// 这里只有值类型；合并规则与 SQL 生成在 PendingChangeEngine（纯逻辑）里。

/// 行的稳定身份。已存在的行用主键值拼出的 key；新增行用 UUID。
struct RowIdentity: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case existing(String)
        case inserted(UUID)
    }

    var kind: Kind

    static func existing(_ key: String) -> RowIdentity { RowIdentity(kind: .existing(key)) }
    static func inserted() -> RowIdentity { RowIdentity(kind: .inserted(UUID())) }

    var isInserted: Bool {
        if case .inserted = kind { return true }
        return false
    }

    var keyString: String? {
        if case .existing(let key) = kind { return key }
        return nil
    }

    var insertID: UUID? {
        if case .inserted(let id) = kind { return id }
        return nil
    }

    /// 主键值拼成稳定字符串。值与值之间用不可打印分隔符，避免歧义。
    static func key(values: [CellValue]) -> String {
        values.map { value -> String in
            switch value {
            case .null: return "\u{0}NULL"
            case .bytes(let bytes): return "\u{0}" + bytes.map { String(format: "%02x", $0) }.joined()
            }
        }.joined(separator: "\u{1}")
    }
}

/// 行定位键：主键列 + 修改前的值。见 docs/tech-designs/08-pending-changes.md §2.1。
struct RowLocator: Hashable, Sendable {
    var columns: [String]
    var values: [CellValue]

    var isEmpty: Bool { columns.isEmpty }

    var display: String {
        zip(columns, values).map { column, value in
            if value.isNull {
                return "\(column) IS NULL"
            }
            return "\(column) = \(value.displayText)"
        }.joined(separator: " AND ")
    }
}

struct PendingRowChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, Codable {
        case insert
        case update
        case delete

        var displayName: String {
            switch self {
            case .insert: return "新增"
            case .update: return "修改"
            case .delete: return "删除"
            }
        }
    }

    var identity: RowIdentity
    var kind: Kind
    var table: TableRef
    /// insert 为 nil
    var locator: RowLocator?
    /// 变更前该行的已知值（用于「改回原值」判定）
    var baseValues: [String: CellValue]
    /// update：被编辑过的列 → 新值；insert：用户填过的列 → 值；delete：[]
    var values: [String: CellValue]

    var id: RowIdentity { identity }

    var changedColumnCount: Int { values.count }
}

/// 变更分类统计，供工具栏 / 状态栏显示。
struct PendingChangeStats: Hashable, Sendable {
    var inserts: Int = 0
    var updates: Int = 0
    var deletes: Int = 0

    var total: Int { inserts + updates + deletes }
    var isEmpty: Bool { total == 0 }

    /// `3 新增 · 2 修改 · 2 删除`（只列出非零项）
    var summary: String {
        var parts: [String] = []
        if inserts > 0 { parts.append("\(inserts) 新增") }
        if updates > 0 { parts.append("\(updates) 修改") }
        if deletes > 0 { parts.append("\(deletes) 删除") }
        return parts.isEmpty ? "无改动" : parts.joined(separator: " · ")
    }
}

/// 将下发的 SQL 语句（Preview 与实际提交共用同一份）。
struct PendingSQLStatement: Identifiable, Hashable, Sendable {
    var id: Int
    var text: String
    var kind: PendingRowChange.Kind
    var identity: RowIdentity
}

/// 提交结果。
struct CommitOutcome: Hashable, Sendable {
    var executedCount: Int
    var elapsed: Duration
    /// 影响 0 行的语句序号（幂等视为成功，仅记录）
    var zeroRowStatements: [Int] = []
}

/// 提交失败。
struct CommitFailure: Error, Hashable, Sendable {
    /// 第几条语句失败（1-based）
    var statementIndex: Int
    var totalStatements: Int
    var error: MySQLServerError
    var statement: String
    /// 服务端崩溃 / 超时导致事务状态未知
    var transactionStateUnknown: Bool = false
    /// 是否已经尝试回滚
    var rolledBack: Bool = false
}
