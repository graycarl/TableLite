import Foundation

/// 语句类型，用于只读拦截与历史分类。见 `docs/tech-designs/10-query-editor.md` §4、§10。
public enum SQLStatementKind: String, Sendable, Codable, CaseIterable, Hashable {
    /// 查询：SELECT / SHOW / EXPLAIN / DESCRIBE / DESC / VALUES / TABLE，以及最终为查询的 `WITH …`。
    case query
    /// 增删改：INSERT / UPDATE / DELETE / REPLACE / LOAD。
    case dml
    /// 结构变更：CREATE / ALTER / DROP / TRUNCATE / RENAME。
    case ddl
    /// 其它（授权、事务控制、CALL 等）。
    case other

    public var displayName: String {
        switch self {
        case .query: return "查询"
        case .dml: return "增删改"
        case .ddl: return "结构变更"
        case .other: return "其它"
        }
    }
}

/// 语句类型判定与只读白名单。
///
/// **注意以 CTE 开头的写语句**（`WITH … INSERT`）：要看首个真正的写关键字，
/// 不能只看第一个 token。见 `docs/tech-designs/10-query-editor.md` §10。
public enum SQLStatementClassifier {
    /// 语句起始关键字（不会返回 `WITH` / `RECURSIVE` / `AS` 这些非起始关键字）。
    static let leadingKeywords: Set<String> = [
        "SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "VALUES", "TABLE",
        "INSERT", "UPDATE", "DELETE", "REPLACE", "LOAD",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME",
        "GRANT", "REVOKE", "SET", "CALL", "LOCK", "UNLOCK", "USE",
        "BEGIN", "COMMIT", "ROLLBACK", "START", "SAVEPOINT",
        "ANALYZE", "OPTIMIZE", "CHECK", "REPAIR", "FLUSH", "RESET", "PURGE",
        "HANDLER", "DO", "HELP",
    ]

    static let queryLeading: Set<String> = ["SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "VALUES", "TABLE"]
    static let dmlLeading: Set<String> = ["INSERT", "UPDATE", "DELETE", "REPLACE", "LOAD"]
    static let ddlLeading: Set<String> = ["CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME"]

    /// 只读连接真正允许的起始关键字（含 `WITH … SELECT` 解析后的 SELECT）。
    static let readOnlyLeading: Set<String> = ["SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC"]

    /// 判定语句类型。
    public static func classify(_ sql: String) -> SQLStatementKind {
        let tokens = significantTokens(sql)
        guard let leading = resolveLeadingKeyword(tokens) else { return .other }
        if queryLeading.contains(leading) { return .query }
        if dmlLeading.contains(leading) { return .dml }
        if ddlLeading.contains(leading) { return .ddl }
        return .other
    }

    /// 是否包含 DDL 关键字（用于元数据缓存失效，`11-schema-and-import-export.md` §1.2）。
    public static func containsDDL(_ sql: String) -> Bool {
        significantTokens(sql).contains { token in
            token.kind == .keyword && ddlLeading.contains(token.text.uppercased())
        }
    }

    /// 只读模式是否放行该语句。
    ///
    /// 白名单见 `specs/09-readonly-mode.md` §4：SELECT / SHOW / EXPLAIN / DESCRIBE / DESC，
    /// 以及最终为查询的 `WITH …`。
    public static func isReadOnlyAllowed(_ sql: String) -> Bool {
        let tokens = significantTokens(sql)
        guard let leading = resolveLeadingKeyword(tokens) else { return false }
        return readOnlyLeading.contains(leading)
    }

    /// 是否是 `USE` 语句。编辑器据此拦截手写切库，统一引导用户走侧栏库切换器
    /// （`docs/tech-designs/10-query-editor.md` §5.5）。
    public static func isUseStatement(_ sql: String) -> Bool {
        resolveLeadingKeyword(significantTokens(sql)) == "USE"
    }

    /// 找出首个真正的起始关键字：
    /// - 跳过注释；
    /// - 只在最外层括号深度上找；
    /// - 跳过 `WITH` / `RECURSIVE` / `AS` 等非起始关键字，直到 CTE 定义之后。
    static func resolveLeadingKeyword(_ tokens: [SQLToken]) -> String? {
        var depth = 0
        for token in tokens {
            if token.kind == .punctuation {
                if token.text == "(" { depth += 1 }
                else if token.text == ")" { depth = max(0, depth - 1) }
                continue
            }
            guard token.kind == .keyword, depth == 0 else { continue }
            let upper = token.text.uppercased()
            if upper == "WITH" || upper == "RECURSIVE" { continue }
            if leadingKeywords.contains(upper) { return upper }
        }
        return nil
    }

    /// 去掉注释后的 token（保留空白语义无关）。
    static func significantTokens(_ sql: String) -> [SQLToken] {
        SQLLexer.tokenize(sql).filter { $0.kind != .comment }
    }
}
