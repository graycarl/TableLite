import Foundation

// MARK: - 过滤器 SQL 生成
//
// 见 docs/tech-designs/09-filtering.md §1.4 §1.5 与 specs/05-filtering.md §1。
//
// 硬约束：值一律走 `SQLValueLiteral`，不做任何手工拼接。
// 纯函数、无 IO。

struct FilterIssue: Hashable, Sendable {
    var conditionID: UUID
    var message: String
}

enum FilterSQLBuilder {

    struct Result: Hashable, Sendable {
        /// nil 表示没有任何有效条件
        var sql: String?
        var issues: [FilterIssue]
    }

    /// raw 模式没有条件行，用这个固定 ID 承载 issue，保证结果可比较、可测试。
    static let rawIssueConditionID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// 生成 WHERE 片段（不含 `WHERE` 关键字）。
    static func build(
        _ filter: FilterSet,
        columns: [TableColumn],
        using literalizer: SQLValueLiteralizer
    ) -> Result {
        // 高级模式：直接返回 rawSQL.trimmingCharacters；含 ';' 只做防呆拒绝（S3）
        if filter.useRawSQL {
            let raw = filter.rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return Result(sql: nil, issues: []) }
            if raw.contains(";") {
                return Result(
                    sql: nil,
                    issues: [FilterIssue(
                        conditionID: rawIssueConditionID,
                        message: "高级条件不能包含分号「;」"
                    )]
                )
            }
            return Result(sql: raw, issues: [])
        }

        var clauses: [String] = []
        var issues: [FilterIssue] = []

        for condition in filter.activeConditions {
            guard let column = columns.first(where: { $0.name == condition.column }) else {
                issues.append(FilterIssue(
                    conditionID: condition.id,
                    message: "找不到列「\(condition.column)」"
                ))
                continue
            }

            let quotedColumn = SQLIdentifier.quote(column.name)
            // 标量值统一去掉首尾空白；空判定也基于 trim 后的结果
            let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let second = condition.secondValue.trimmingCharacters(in: .whitespacesAndNewlines)

            switch condition.op {
            case .isNull:
                clauses.append("(\(quotedColumn) IS NULL)")

            case .isNotNull:
                clauses.append("(\(quotedColumn) IS NOT NULL)")

            case .between:
                guard !value.isEmpty, !second.isEmpty else {
                    issues.append(FilterIssue(
                        conditionID: condition.id,
                        message: "「\(condition.op.displayName)」需要两个值"
                    ))
                    continue
                }
                let lower = literal(value, column: column, using: literalizer)
                let upper = literal(second, column: column, using: literalizer)
                clauses.append("(\(quotedColumn) BETWEEN \(lower) AND \(upper))")

            case .inList:
                let items = condition.value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !items.isEmpty else {
                    issues.append(FilterIssue(
                        conditionID: condition.id,
                        message: "「\(condition.op.displayName)」至少需要一个值"
                    ))
                    continue
                }
                let list = items
                    .map { literal($0, column: column, using: literalizer) }
                    .joined(separator: ", ")
                clauses.append("(\(quotedColumn) IN (\(list)))")

            case .contains, .notContains, .beginsWith, .endsWith:
                guard !value.isEmpty else {
                    issues.append(missingValueIssue(condition))
                    continue
                }
                // 先对用户输入做 LIKE 转义（\ % _），拼成 pattern，再走字面量路径
                let pattern = likePattern(op: condition.op, value: value)
                let patternLiteral = SQLValueLiteral.literal(
                    CellValue.text(pattern), kind: .text, using: literalizer
                )
                let keyword = condition.op == .notContains ? "NOT LIKE" : "LIKE"
                // 显式 ESCAPE '\\'，避免受 NO_BACKSLASH_ESCAPES 影响
                clauses.append("(\(quotedColumn) \(keyword) \(patternLiteral) ESCAPE '\\\\')")

            default:
                guard !value.isEmpty else {
                    issues.append(missingValueIssue(condition))
                    continue
                }
                let symbol = comparisonSymbol(condition.op)
                clauses.append("(\(quotedColumn) \(symbol) \(literal(value, column: column, using: literalizer)))")
            }
        }

        guard !clauses.isEmpty else { return Result(sql: nil, issues: issues) }
        let joiner = filter.logic == .all ? " AND " : " OR "
        return Result(sql: clauses.joined(separator: joiner), issues: issues)
    }

    // MARK: 内部

    private static func literal(
        _ value: String,
        column: TableColumn,
        using literalizer: SQLValueLiteralizer
    ) -> String {
        SQLValueLiteral.literal(CellValue.text(value), kind: column.kind, using: literalizer)
    }

    private static func missingValueIssue(_ condition: FilterCondition) -> FilterIssue {
        FilterIssue(
            conditionID: condition.id,
            message: "「\(condition.op.displayName)」缺少值"
        )
    }

    private static func comparisonSymbol(_ op: FilterOperator) -> String {
        switch op {
        case .equal: return "="
        case .notEqual: return "<>"
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        default: return "="
        }
    }

    /// LIKE / NOT LIKE 的 pattern：先转义 `\` `%` `_`，再加通配符。
    private static func likePattern(op: FilterOperator, value: String) -> String {
        let escaped = escapeLike(value)
        switch op {
        case .contains, .notContains:
            return "%\(escaped)%"
        case .beginsWith:
            return "\(escaped)%"
        case .endsWith:
            return "%\(escaped)"
        default:
            return escaped
        }
    }

    private static func escapeLike(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\", "%", "_":
                output.append("\\")
                output.append(character)
            default:
                output.append(character)
            }
        }
        return output
    }
}
