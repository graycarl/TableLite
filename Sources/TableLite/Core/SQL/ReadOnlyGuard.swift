import Foundation

// MARK: - 只读模式白名单拦截
//
// 见 docs/tech-designs/10-query-editor.md §10、specs/09-readonly-mode.md §4：
// 只放行 SELECT / SHOW / EXPLAIN / DESCRIBE / DESC，以及最终为查询的 `WITH ... SELECT`。
// 注意 `WITH ... INSERT/UPDATE/DELETE` 必须被拒绝，因此要看首个真正的写关键字，
// 不能只看第一个 token。

enum ReadOnlyDecision: Hashable, Sendable {
    case allowed
    /// reason 是给用户看的中文
    case rejected(reason: String)
}

enum ReadOnlyGuard {

    /// 给 UI 的简短说明（specs/09-readonly-mode.md §5 的唯一真源）。
    static var rejectionMessage: String { "只读模式：写操作已被禁用" }

    private static let allowedKeywords: Set<String> = [
        "SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC",
    ]

    /// 白名单判定。重新词法扫描，避免仅凭 `firstKeyword` 漏掉 `WITH ... INSERT`。
    static func evaluate(_ statement: SQLStatement) -> ReadOnlyDecision {
        let tokens = SQLLexer.tokenize(statement.text)
        guard let keyword = SQLLexer.leadingKeyword(tokens: tokens, text: statement.text) else {
            // 没有可识别的主关键字（空语句 / 纯注释）→ 拒绝
            return .rejected(reason: rejectionMessage)
        }
        if allowedKeywords.contains(keyword) {
            return .allowed
        }
        return .rejected(reason: rejectionMessage)
    }
}
