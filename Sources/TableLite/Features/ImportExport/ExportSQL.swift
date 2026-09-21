import Foundation

// MARK: - 导出用 SQL 纯逻辑
//
// 见 docs/tech-designs/11-schema-and-import-export.md §3.1 §3.2、
// specs/08-import-export.md §1。
//
// 硬约束（L2）：宁可少导出也不要导错——顶层 `LIMIT` 无法安全剥掉时**不改动 SQL**，
// 由导出面板写明「将导出本次实际返回的行」。

enum ExportSQL {

    /// 剥顶层 `LIMIT` 的结果。三种情况都能拿到一个可直接执行的 SQL。
    enum LimitStrip: Equatable, Sendable {
        /// 成功剥掉顶层 `LIMIT`。
        case stripped(String)
        /// 本来就没有顶层 `LIMIT`，原样导出完整结果。
        case unchanged(String)
        /// 存在顶层 `LIMIT` 但无法安全判断（顶层 `UNION`、`LIMIT` 后还有别的子句、
        /// 或 `LIMIT` 只在子查询里），**不改动 SQL**。
        case ambiguous(String)

        /// 处理后可执行的 SQL。
        var sql: String {
            switch self {
            case .stripped(let sql), .unchanged(let sql), .ambiguous(let sql):
                return sql
            }
        }

        /// 是否真的剥掉了顶层 `LIMIT`。
        var didStripLimit: Bool {
            if case .stripped = self { return true }
            return false
        }

        /// 是否存在无法安全判断的构造（此时调用方应提示「将导出本次实际返回的行」）。
        var isAmbiguous: Bool {
            if case .ambiguous = self { return true }
            return false
        }
    }

    /// 剥掉最后一个顶层 `LIMIT`。
    ///
    /// 规则（docs/11 §3.2）：
    /// - `LIMIT` 出现在子查询里（括号深度 > 0）不算顶层，返回 `.unchanged`；
    /// - 顶层出现 `UNION` 时语义不确定，返回 `.ambiguous` 且不改 SQL；
    /// - `LIMIT` 后面还有别的子句（例如 `FOR UPDATE`）同样按 `.ambiguous` 处理；
    /// - 大小写不敏感；`LIMIT 10` / `LIMIT 10 OFFSET 20` / `LIMIT 20, 10` 都识别；
    /// - 允许结尾分号与注释。
    ///
    /// 纯函数，基于 `SQLLexer` 的 token（字符串 / 注释 / 反引号里的 `LIMIT` 不会被误判）。
    static func stripTopLevelLimit(_ sql: String) -> LimitStrip {
        let tokens = SQLLexer.tokenize(sql)
        var depth = 0
        var limitIndex: Int?
        var sawTopLevelUnion = false

        for (index, token) in tokens.enumerated() {
            if token.kind == .punctuation {
                switch SQLLexer.text(of: token, in: sql) {
                case "(": depth += 1
                case ")": depth = max(0, depth - 1)
                default: break
                }
                continue
            }
            guard token.kind == .keyword, depth == 0 else { continue }
            let word = SQLLexer.text(of: token, in: sql).uppercased()
            if word == "UNION" { sawTopLevelUnion = true }
            if word == "LIMIT" { limitIndex = index }
        }

        guard let limitIndex else { return .unchanged(sql) }
        if sawTopLevelUnion { return .ambiguous(sql) }
        guard isSingleLimitClause(tokens: tokens, from: limitIndex + 1, in: sql) else {
            return .ambiguous(sql)
        }

        // `SQLLexer` 的 range 基于 UTF-16，用 NSString 切片保持同一坐标系。
        let prefix = (sql as NSString).substring(to: tokens[limitIndex].range.location)
        return .stripped(trimTrailingWhitespace(prefix))
    }

    /// 选中行导出：`SELECT <投影> FROM <表> WHERE (<定位键1>) OR (<定位键2>) …`。
    ///
    /// 行定位键用主键 + 修改前的值，与手工编辑走同一套字面量路径。
    /// 无主键（无法定位）时返回 nil，由调用方回退到内存里的选中行。
    static func selectedRowsSQL(ref: TableRef,
                                structure: TableStructure,
                                locators: [RowLocator],
                                literalizer: SQLValueLiteralizer) -> String? {
        let clauses = locators
            .filter { !$0.isEmpty }
            .map { locator in
                "(" + TableDataQueryBuilder.whereClause(for: locator,
                                                        structure: structure,
                                                        literalizer: literalizer) + ")"
            }
        guard !clauses.isEmpty else { return nil }

        let projections = TableDataQueryBuilder.projection(structure: structure, lazyLarge: false)
        let selectList = TableDataQueryBuilder.selectList(
            ref: ref,
            projections: projections,
            largeThreshold: TableDataQueryBuilder.defaultLargeThreshold
        )
        var sql = "SELECT \(selectList) FROM \(SQLIdentifier.qualified(ref.database, ref.table))"
        sql += " WHERE " + clauses.joined(separator: " OR ")
        return sql
    }

    /// 过滤条件摘要（导出面板「源」下方那行括号说明）。没有有效条件时返回 nil。
    ///
    /// 纯展示文本，不参与 SQL 生成。
    static func filterSummary(_ filter: FilterSet) -> String? {
        guard !filter.isEmpty else { return nil }
        if filter.useRawSQL {
            let raw = filter.rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }

        let parts = filter.activeConditions.map { condition -> String in
            switch condition.op {
            case .isNull, .isNotNull:
                return "\(condition.column) \(condition.op.displayName)"
            case .between:
                return "\(condition.column) \(condition.op.displayName) \(condition.value) 与 \(condition.secondValue)"
            default:
                return "\(condition.column) \(condition.op.displayName) \(condition.value)"
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: filter.logic == .all ? " 且 " : " 或 ")
    }

    // MARK: - 内部

    /// `LIMIT` 之后是否只跟合法的行数表达式（数字 / 占位 / `OFFSET` / 逗号 / 结尾分号）。
    ///
    /// 只要出现别的子句（`FOR`、`UNION`、第二个 `LIMIT`…）就判定为不确定。
    private static func isSingleLimitClause(tokens: [SQLToken],
                                            from start: Int,
                                            in sql: String) -> Bool {
        var operandCount = 0
        var sawSemicolon = false
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            if token.kind == .comment { index += 1; continue }
            if sawSemicolon { return false }

            switch token.kind {
            case .number, .parameter, .variable:
                operandCount += 1
            case .keyword:
                guard SQLLexer.text(of: token, in: sql).uppercased() == "OFFSET" else { return false }
            case .punctuation:
                switch SQLLexer.text(of: token, in: sql) {
                case ",": break
                case ";": sawSemicolon = true
                default: return false
                }
            default:
                return false
            }
            index += 1
        }
        return operandCount > 0
    }

    /// 去掉结尾空白，保留开头的空白 / 换行（尽量不动用户的原始排版）。
    private static func trimTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            let character = text[previous]
            if character.isWhitespace {
                end = previous
            } else {
                break
            }
        }
        return String(text[text.startIndex..<end])
    }
}
