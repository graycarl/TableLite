import Foundation

/// 从查询结果导出时，尝试剥掉最后一个**顶层** `LIMIT`。
///
/// 硬约束见 `docs/tech-designs/11-schema-and-import-export.md` §3.2（L2）：
/// 解析不确定时（`LIMIT` 在子查询里、含 `UNION`、语法不在预期内）**不修改 SQL**，
/// 由调用方在导出面板明确写出「将导出本次实际返回的 N 行」。
///
/// 纯函数，不依赖任何连接。
public enum SQLLimitRemoval {

    /// 剥离结果。
    public enum Outcome: Sendable, Equatable {
        /// 成功移除了一个顶层 `LIMIT`。
        case stripped(removedClause: String)
        /// 没有可移除的 `LIMIT`（本来就返回全部行）。
        case absent
        /// 无法安全判断，保持原样。
        case uncertain(reason: UncertainReason)
    }

    public enum UncertainReason: String, Sendable, Equatable {
        /// 含顶层 `UNION`：`LIMIT` 的语义与排序耦合，不猜。
        case union
        /// 有多个顶层 `LIMIT`。
        case multipleLimit
        /// `LIMIT` 只出现在子查询里。
        case subqueryLimit
        /// `LIMIT` 后面的语法不在预期内。
        case unparsable

        public var displayText: String {
            switch self {
            case .union: return "查询包含 UNION"
            case .multipleLimit: return "查询有多个 LIMIT"
            case .subqueryLimit: return "LIMIT 位于子查询中"
            case .unparsable: return "LIMIT 的写法无法解析"
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public var sql: String
        public var outcome: Outcome

        public init(sql: String, outcome: Outcome) {
            self.sql = sql
            self.outcome = outcome
        }

        public var didStrip: Bool {
            if case .stripped = outcome { return true }
            return false
        }

        /// 面板上的说明文案；`nil` 表示无需额外提示。
        public var note: String? {
            switch outcome {
            case .stripped(let clause):
                return "已移除顶层 \(clause)，将导出全部行"
            case .absent:
                return nil
            case .uncertain(let reason):
                return "无法安全移除 LIMIT（\(reason.displayText)），将导出本次实际返回的行数"
            }
        }
    }

    // MARK: - 主入口

    public static func removingTopLevelLimit(_ sql: String) -> Result {
        let characters = Array(sql)
        let tokens = tokenize(characters)

        let topLevel = tokens.filter { $0.depth == 0 }
        let hasUnion = topLevel.contains { $0.upper == "UNION" }
        let topLevelLimits = topLevel.enumerated().filter { $0.element.upper == "LIMIT" }

        if hasUnion {
            return Result(sql: sql, outcome: .uncertain(reason: .union))
        }
        if topLevelLimits.count > 1 {
            return Result(sql: sql, outcome: .uncertain(reason: .multipleLimit))
        }
        guard let limitPosition = topLevelLimits.first?.offset else {
            let hasNestedLimit = tokens.contains { $0.upper == "LIMIT" }
            return Result(sql: sql, outcome: hasNestedLimit ? .uncertain(reason: .subqueryLimit) : .absent)
        }

        let limitToken = topLevel[limitPosition]
        guard let clauseEnd = validateLimitClause(topLevel, from: limitPosition) else {
            return Result(sql: sql, outcome: .uncertain(reason: .unparsable))
        }

        let removedStart = limitToken.start
        let removedClause = String(characters[removedStart..<clauseEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(characters[0..<removedStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tailHasSemicolon = characters[clauseEnd...].contains { $0 == ";" }
        let stripped = head + (tailHasSemicolon ? ";" : "")
        return Result(sql: stripped, outcome: .stripped(removedClause: removedClause))
    }

    // MARK: - 词法扫描

    struct Token: Sendable, Equatable {
        var upper: String
        var depth: Int
        /// 在 `[Character]` 里的起始下标。
        var start: Int
        /// 结束下标（不含）。
        var end: Int
    }

    /// 只保留有意义的 token：标识符 / 数字 / 字符串占位 / 括号 / 逗号 / 分号。
    /// 注释与字符串内容被跳过，但字符串会以 `''` 形式记录，以便定位 `LIMIT` 之后的内容。
    static func tokenize(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var depth = 0
        var index = 0

        func append(_ upper: String, start: Int, end: Int) {
            tokens.append(Token(upper: upper, depth: depth, start: start, end: end))
        }

        while index < characters.count {
            let character = characters[index]

            // 字符串：`'…'` / `"…"` / 反引号标识符
            if character == "'" || character == "\"" || character == "`" {
                let quote = character
                let start = index
                index += 1
                var escaped = false
                while index < characters.count {
                    let current = characters[index]
                    if escaped {
                        escaped = false
                        index += 1
                        continue
                    }
                    if current == "\\" {
                        escaped = true
                        index += 1
                        continue
                    }
                    if current == quote {
                        // 双写表示一个字面引号。
                        if index + 1 < characters.count, characters[index + 1] == quote {
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                append("''", start: start, end: index)
                continue
            }

            // 行注释 `-- …` / `# …`
            if character == "#" {
                index = scanToLineEnd(characters, from: index)
                continue
            }
            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                index = scanToLineEnd(characters, from: index)
                continue
            }
            // 块注释 `/* … */`
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count,
                      !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                continue
            }

            if character == "(" {
                depth += 1
                index += 1
                continue
            }
            if character == ")" {
                depth = max(0, depth - 1)
                index += 1
                continue
            }
            if character == "," || character == ";" {
                append(String(character), start: index, end: index + 1)
                index += 1
                continue
            }
            if character.isLetter || character.isNumber || character == "_" || character == "$" || character == "?" {
                let start = index
                while index < characters.count {
                    let current = characters[index]
                    guard current.isLetter || current.isNumber || current == "_" || current == "$" || current == "?" else {
                        break
                    }
                    index += 1
                }
                append(String(characters[start..<index]).uppercased(), start: start, end: index)
                continue
            }

            index += 1
        }
        return tokens
    }

    private static func scanToLineEnd(_ characters: [Character], from index: Int) -> Int {
        var current = index
        while current < characters.count, characters[current] != "\n" {
            current += 1
        }
        return current
    }

    // MARK: - LIMIT 子句校验

    /// `LIMIT` 之后的合法形态：`n` / `offset, n` / `n OFFSET offset`，末尾只允许 `;`。
    /// 返回子句结束的下标（分号前），不合法返回 nil。
    static func validateLimitClause(_ topLevel: [Token], from limitPosition: Int) -> Int? {
        var cursor = limitPosition + 1

        func isWord(_ token: Token) -> Bool {
            token.upper != "," && token.upper != ";"
        }

        guard cursor < topLevel.count, isWord(topLevel[cursor]) else { return nil }
        cursor += 1

        if cursor < topLevel.count, topLevel[cursor].upper == "," {
            cursor += 1
            guard cursor < topLevel.count, isWord(topLevel[cursor]) else { return nil }
            cursor += 1
        } else if cursor < topLevel.count, topLevel[cursor].upper == "OFFSET" {
            cursor += 1
            guard cursor < topLevel.count, isWord(topLevel[cursor]) else { return nil }
            cursor += 1
        }

        // 只允许分号收尾。
        if cursor < topLevel.count {
            guard topLevel[cursor].upper == ";" else { return nil }
            cursor += 1
            guard cursor == topLevel.count else { return nil }
            return topLevel[cursor - 1].start
        }
        return topLevel[cursor - 1].end
    }
}
