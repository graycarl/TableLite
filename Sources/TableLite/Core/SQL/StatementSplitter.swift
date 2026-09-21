import Foundation

// MARK: - SQL 语句拆分
//
// 按分号拆分，但忽略字符串 / 反引号 / 注释内的分号；结尾无分号的非空段也算一条。
// 见 docs/tech-designs/10-query-editor.md §4。
//
// 产出保留原文（含结尾分号），下发时不再补分号。

enum SQLStatementKind: String, Hashable, Sendable {
    case query
    case dml
    case ddl
    case transaction
    case other
}

struct SQLStatement: Hashable, Sendable {
    /// 保留原文（含结尾分号），下发时不再补
    var text: String
    var range: NSRange
    var kind: SQLStatementKind
    /// 大写，例如 "SELECT" / "WITH" / "INSERT"
    var firstKeyword: String
}

enum StatementSplitter {

    /// 分号分隔，但忽略字符串 / 反引号 / 注释内的分号；结尾无分号的最后一段也算一条；
    /// 空语句与纯注释段跳过。
    static func split(_ sql: String) -> [SQLStatement] {
        let units = Array(sql.utf16)
        let n = units.count
        let ns = sql as NSString
        var statements: [SQLStatement] = []

        var segmentStart = 0
        var i = 0
        var state = ScanState.normal

        func flush(_ end: Int) {
            guard end > segmentStart else { return }
            let range = NSRange(location: segmentStart, length: end - segmentStart)
            let text = ns.substring(with: range)
            if let statement = makeStatement(text: text, range: range) {
                statements.append(statement)
            }
        }

        while i < n {
            let c = units[i]
            switch state {
            case .normal:
                if c == .singleQuote {
                    state = .singleQuote; i += 1
                } else if c == .doubleQuote {
                    state = .doubleQuote; i += 1
                } else if c == .backtick {
                    state = .backtick; i += 1
                } else if c == .slash, i + 1 < n, units[i + 1] == .star {
                    state = .blockComment; i += 2
                } else if c == .minus, i + 1 < n, units[i + 1] == .minus,
                          i + 2 >= n || units[i + 2] <= 0x20 {
                    state = .lineComment; i += 2
                } else if c == .hash {
                    state = .lineComment; i += 1
                } else if c == .semicolon {
                    // 分号属于本条语句原文
                    flush(i + 1)
                    segmentStart = i + 1
                    i += 1
                } else {
                    i += 1
                }

            case .singleQuote:
                if c == .backslash {
                    i += 2
                } else if c == .singleQuote {
                    if i + 1 < n, units[i + 1] == .singleQuote { i += 2 }
                    else { state = .normal; i += 1 }
                } else {
                    i += 1
                }

            case .doubleQuote:
                if c == .backslash {
                    i += 2
                } else if c == .doubleQuote {
                    if i + 1 < n, units[i + 1] == .doubleQuote { i += 2 }
                    else { state = .normal; i += 1 }
                } else {
                    i += 1
                }

            case .backtick:
                if c == .backtick {
                    if i + 1 < n, units[i + 1] == .backtick { i += 2 }
                    else { state = .normal; i += 1 }
                } else {
                    i += 1
                }

            case .blockComment:
                if c == .star, i + 1 < n, units[i + 1] == .slash {
                    state = .normal; i += 2
                } else {
                    i += 1
                }

            case .lineComment:
                if c == .newline || c == .carriageReturn {
                    state = .normal; i += 1
                } else {
                    i += 1
                }
            }
        }

        // 结尾没有分号的最后一段
        flush(n)
        return statements
    }

    // MARK: 内部

    private enum ScanState {
        case normal
        case singleQuote
        case doubleQuote
        case backtick
        case blockComment
        case lineComment
    }

    /// 把一段原文变成语句；空段 / 纯注释段返回 nil。
    private static func makeStatement(text: String, range: NSRange) -> SQLStatement? {
        let tokens = SQLLexer.tokenize(text)
        // 跳过空语句与纯注释段；但 `/*! ... */` 版本注释会被服务器执行，不能当普通注释丢掉。
        let hasMeaningfulToken = tokens.contains { token in
            switch token.kind {
            case .comment:
                return SQLLexer.text(of: token, in: text).hasPrefix("/*!")
            case .punctuation:
                return SQLLexer.text(of: token, in: text) != ";"
            default:
                return true
            }
        }
        guard hasMeaningfulToken else { return nil }

        let firstKeyword = tokens.first(where: { $0.kind == .keyword })
            .map { SQLLexer.text(of: $0, in: text).uppercased() } ?? ""
        // WITH 开头的语句，类型取决于 CTE 之后真正的主语句关键字
        let effective = SQLLexer.leadingKeyword(tokens: tokens, text: text) ?? firstKeyword
        return SQLStatement(
            text: text,
            range: range,
            kind: kind(for: effective),
            firstKeyword: firstKeyword
        )
    }

    private static func kind(for keyword: String) -> SQLStatementKind {
        switch keyword {
        case "SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC":
            return .query
        case "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE":
            return .dml
        case "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME":
            return .ddl
        case "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "XA":
            return .transaction
        default:
            return .other
        }
    }
}

// MARK: - 字符常量（与 SQLLexer 对称，文件内私有）

private extension UInt16 {
    static let newline: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let doubleQuote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let singleQuote: UInt16 = 0x27
    static let star: UInt16 = 0x2A
    static let minus: UInt16 = 0x2D
    static let slash: UInt16 = 0x2F
    static let semicolon: UInt16 = 0x3B
    static let backslash: UInt16 = 0x5C
    static let backtick: UInt16 = 0x60
}
