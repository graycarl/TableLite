import Foundation

/// 过滤器生成 SQL 时的错误。
public enum FilterBuildError: Error, Sendable, Equatable {
    /// 条件引用了不存在的列。
    case unknownColumns(columns: [String], conditionIDs: [UUID])
    /// `IN` 列表为空。
    case emptyInList(column: String)
    /// 高级模式里出现了 `;`（防呆检查）。
    case rawContainsSemicolon

    public var message: String {
        switch self {
        case .unknownColumns(let columns, _):
            return "过滤条件引用了不存在的列：\(columns.joined(separator: "、"))"
        case .emptyInList(let column):
            return "「\(column)」的在列表中条件没有填写任何值"
        case .rawContainsSemicolon:
            return "高级条件里不能包含分号「;」"
        }
    }
}

/// `WHERE` 生成结果。
public struct FilterBuildResult: Sendable, Equatable {
    /// 不含 `WHERE` 前缀的条件文本；没有任何有效条件时为 nil。
    public var clause: String?
    /// 需要值的操作符遇到空输入，被跳过的条件（界面上标黄）。
    public var skippedConditionIDs: [UUID]

    public init(clause: String?, skippedConditionIDs: [UUID] = []) {
        self.clause = clause
        self.skippedConditionIDs = skippedConditionIDs
    }

    public var isEmpty: Bool { clause == nil }
}

/// 把 `FilterState` 转成 `WHERE` 片段。
///
/// 硬约束见 `docs/tech-designs/09-filtering.md` §1.4：
/// - 值一律走 `SQLValueLiteral`，不做任何手工拼接；
/// - `LIKE` 的 `%` 与 `_` 先转义，再加 `ESCAPE '\\'`；
/// - 数字列且值通过严格数字正则时才不带引号；
/// - 每条条件可用括号包住后按 AND / OR 连接，不做嵌套括号分组。
public enum FilterSQLBuilder {
    public static func whereClause(
        for state: FilterState,
        columns: [ColumnInfo],
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil
    ) throws -> FilterBuildResult {
        if state.isRawMode {
            let raw = state.rawWhere.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return FilterBuildResult(clause: nil) }
            if raw.contains(";") { throw FilterBuildError.rawContainsSemicolon }
            return FilterBuildResult(clause: raw)
        }

        // 先校验列是否存在（启用中的条件都校验，包括尚未填值的）。
        let columnLookup = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var unknown: [String] = []
        var unknownIDs: [UUID] = []
        for condition in state.conditions where condition.isEnabled {
            if columnLookup[condition.column] == nil {
                unknown.append(condition.column)
                unknownIDs.append(condition.id)
            }
        }
        if !unknown.isEmpty {
            throw FilterBuildError.unknownColumns(columns: unknown, conditionIDs: unknownIDs)
        }

        var parts: [String] = []
        var skipped: [UUID] = []
        for condition in state.conditions {
            guard condition.isEnabled else { continue }
            if condition.isIncomplete {
                skipped.append(condition.id)
                continue
            }
            let column = columnLookup[condition.column]
            let clause = try clause(
                for: condition,
                column: column,
                escaping: escaping,
                introducer: introducer
            )
            parts.append("(\(clause))")
        }

        guard !parts.isEmpty else {
            return FilterBuildResult(clause: nil, skippedConditionIDs: skipped)
        }
        return FilterBuildResult(
            clause: parts.joined(separator: " \(state.combination.keyword) "),
            skippedConditionIDs: skipped
        )
    }

    /// 转义 `LIKE` 模式里的 `\`、`%`、`_`。结果随后还要经过 `SQLValueLiteral` 的字面量转义。
    public static func escapeLikePattern(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "%": result += "\\%"
            case "_": result += "\\_"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: 跨列快速过滤

    /// 快速过滤：对给定的每一列做 `col LIKE '%文本%'`，用 `OR` 连接。
    ///
    /// 与条件行 / Raw 并存：由调用方用 `combine(_:_:)` 再与主条件 `AND` 组合。
    /// 二进制列会被跳过（对二进制做 `LIKE` 无意义且易误导）。
    public static func quickFilterClause(
        _ text: String,
        columns: [ColumnInfo],
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let eligible = columns.filter { !$0.isBinary && $0.fieldType != .null }
        guard !eligible.isEmpty else { return nil }
        let pattern = "%\(escapeLikePattern(trimmed))%"
        let parts = eligible.map { column in
            likeClause(
                SQLIdentifier.quote(column.name),
                pattern: pattern,
                negated: false,
                escaping: escaping,
                introducer: introducer
            )
        }
        return "(\(parts.joined(separator: " OR ")))"
    }

    /// 把两段 `WHERE` 片段用 `AND` 组合；任一侧为 nil 时直接返回另一侧。
    public static func combine(_ lhs: String?, _ rhs: String?) -> String? {
        if let lhs, let rhs { return "(\(lhs)) AND (\(rhs))" }
        return lhs ?? rhs
    }

    // MARK: 单条条件

    static func clause(
        for condition: FilterCondition,
        column: ColumnInfo?,
        escaping: SQLStringEscaping,
        introducer: String?
    ) throws -> String {
        let quotedColumn = SQLIdentifier.quote(condition.column)
        let fieldType = column?.fieldType ?? .varString
        let isBinary = column?.isBinary ?? false

        func valueLiteral(_ text: String, trim: Bool = false) -> String {
            let value = trim ? text.trimmingCharacters(in: .whitespaces) : text
            return SQLValueLiteral.literal(
                for: .text(value),
                fieldType: fieldType,
                isBinaryColumn: isBinary,
                escaping: escaping,
                introducer: introducer
            )
        }

        switch condition.op {
        case .isNull:
            return "\(quotedColumn) IS NULL"
        case .isNotNull:
            return "\(quotedColumn) IS NOT NULL"
        case .equal:
            return "\(quotedColumn) = \(valueLiteral(condition.value))"
        case .notEqual:
            return "\(quotedColumn) <> \(valueLiteral(condition.value))"
        case .greaterThan:
            return "\(quotedColumn) > \(valueLiteral(condition.value, trim: true))"
        case .greaterThanOrEqual:
            return "\(quotedColumn) >= \(valueLiteral(condition.value, trim: true))"
        case .lessThan:
            return "\(quotedColumn) < \(valueLiteral(condition.value, trim: true))"
        case .lessThanOrEqual:
            return "\(quotedColumn) <= \(valueLiteral(condition.value, trim: true))"
        case .contains:
            return likeClause(quotedColumn, pattern: "%\(escapeLikePattern(condition.value))%", negated: false, escaping: escaping, introducer: introducer)
        case .notContains:
            return likeClause(quotedColumn, pattern: "%\(escapeLikePattern(condition.value))%", negated: true, escaping: escaping, introducer: introducer)
        case .beginsWith:
            return likeClause(quotedColumn, pattern: "\(escapeLikePattern(condition.value))%", negated: false, escaping: escaping, introducer: introducer)
        case .endsWith:
            return likeClause(quotedColumn, pattern: "%\(escapeLikePattern(condition.value))", negated: false, escaping: escaping, introducer: introducer)
        case .between:
            let low = valueLiteral(condition.value, trim: true)
            let high = valueLiteral(condition.secondValue, trim: true)
            return "\(quotedColumn) BETWEEN \(low) AND \(high)"
        case .inList:
            let items = condition.value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { throw FilterBuildError.emptyInList(column: condition.column) }
            let literals = items.map { valueLiteral($0) }.joined(separator: ", ")
            return "\(quotedColumn) IN (\(literals))"
        }
    }

    static func likeClause(
        _ quotedColumn: String,
        pattern: String,
        negated: Bool,
        escaping: SQLStringEscaping,
        introducer: String?
    ) -> String {
        let patternLiteral = SQLValueLiteral.literal(
            for: .text(pattern),
            fieldType: .varString,
            escaping: escaping,
            introducer: introducer
        )
        // 显式 ESCAPE，避免受 NO_BACKSLASH_ESCAPES 影响。
        let escapeLiteral = escaping == .mysqlDefault ? "'\\\\'" : "'\\'"
        let keyword = negated ? "NOT LIKE" : "LIKE"
        return "\(quotedColumn) \(keyword) \(patternLiteral) ESCAPE \(escapeLiteral)"
    }
}
