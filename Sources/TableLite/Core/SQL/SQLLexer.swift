import Foundation

// MARK: - SQL 词法扫描
//
// 手写单向扫描器，输出 `(range, token)`，供语法高亮与语句拆分共用。
// 见 docs/tech-designs/10-query-editor.md §3 §4。
//
// 约束：
// - `NSRange` 一律基于 UTF-16（与 `NSTextStorage` 一致），因此内部用 `Array(sql.utf16)` 扫描。
// - surrogate pair（emoji）按两个 UTF-16 code unit 处理，扫描时不拆开也不会越界。
// - 纯函数、无 IO。

enum SQLTokenKind: Hashable, Sendable {
    case keyword
    case function
    case type
    case string
    case backtick
    case number
    case comment
    case variable
    case parameter
    case operatorSymbol
    case punctuation
    case identifier
}

struct SQLToken: Hashable, Sendable {
    /// 对 UTF-16 的偏移，和 NSTextStorage 一致
    var range: NSRange
    var kind: SQLTokenKind
}

enum SQLLexer {

    // MARK: 对外入口

    /// 单向扫描，输出 `(range, token)`。
    static func tokenize(_ sql: String) -> [SQLToken] {
        let units = Array(sql.utf16)
        let n = units.count
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(n / 4)

        func add(_ start: Int, _ end: Int, _ kind: SQLTokenKind) {
            tokens.append(SQLToken(range: NSRange(location: start, length: end - start), kind: kind))
        }

        var i = 0
        while i < n {
            let c = units[i]

            // 空白：不产出 token
            if isWhitespace(c) { i += 1; continue }

            // /* ... */ 与 /*! ... */ 版本注释统一按注释处理
            if c == .slash, i + 1 < n, units[i + 1] == .star {
                var j = i + 2
                var closed = false
                while j + 1 < n {
                    if units[j] == .star, units[j + 1] == .slash { j += 2; closed = true; break }
                    j += 1
                }
                if !closed { j = n }
                add(i, j, .comment); i = j; continue
            }

            // `-- ` 行注释：MySQL 要求第二个减号后是空白/控制字符或行尾，否则是减号运算符
            if c == .minus, i + 1 < n, units[i + 1] == .minus {
                if i + 2 >= n || isCommentFollow(units[i + 2]) {
                    var j = i + 2
                    while j < n, units[j] != .newline, units[j] != .carriageReturn { j += 1 }
                    add(i, j, .comment); i = j; continue
                }
            }

            // `#` 行注释
            if c == .hash {
                var j = i + 1
                while j < n, units[j] != .newline, units[j] != .carriageReturn { j += 1 }
                add(i, j, .comment); i = j; continue
            }

            // 字符串（单引号 / 双引号），兼容 `''` / `\"` / `\'` / `""`
            if c == .singleQuote {
                let j = scanQuoted(units, from: i, quote: .singleQuote)
                add(i, j, .string); i = j; continue
            }
            if c == .doubleQuote {
                let j = scanQuoted(units, from: i, quote: .doubleQuote)
                add(i, j, .string); i = j; continue
            }

            // 反引号标识符：内部任意内容，`` 为转义
            if c == .backtick {
                let j = scanBacktick(units, from: i)
                add(i, j, .backtick); i = j; continue
            }

            // `?` 参数占位
            if c == .questionMark {
                add(i, i + 1, .parameter); i += 1; continue
            }

            // `@var` / `@@global.x` 变量
            if c == .at {
                var j = i + 1
                if j < n, units[j] == .at { j += 1 }
                while j < n, isVariableChar(units[j]) { j += 1 }
                add(i, j, .variable); i = j; continue
            }

            // 数字：123 / 1.5 / .5 / 0xFF / 0b01 / 1e5
            if isDigit(c) || (c == .dot && i + 1 < n && isDigit(units[i + 1])) {
                let j = scanNumber(units, from: i)
                add(i, j, .number); i = j; continue
            }

            // 标识符 / 关键字 / 函数 / 类型
            if isIdentifierStart(c) {
                var j = i + 1
                while j < n, isIdentifierPart(units[j]) { j += 1 }
                let word = String(decoding: units[i..<j], as: UTF16.self)
                let kind = classifyWord(word, followedByParen: followedByOpenParen(units, from: j))
                add(i, j, kind); i = j; continue
            }

            // 运算符
            if let length = operatorLength(units, at: i) {
                add(i, i + length, .operatorSymbol); i += length; continue
            }

            // 标点
            if isPunctuation(c) {
                add(i, i + 1, .punctuation); i += 1; continue
            }

            // 兜底：未知单个 code unit 当标识符，保证扫描不卡死
            add(i, i + 1, .identifier); i += 1
        }
        return tokens
    }

    /// 取 token 对应的原文（按 UTF-16 range）。
    static func text(of token: SQLToken, in sql: String) -> String {
        guard let range = Range(token.range, in: sql) else { return "" }
        return String(sql[range])
    }

    /// 语句「真正的主导关键字」。
    ///
    /// 普通语句返回第一个关键字；以 `WITH` 开头时继续找 CTE 结束后的主语句关键字，
    /// 因此 `WITH ... INSERT` 会返回 `INSERT` 而不是 `WITH`。
    /// 见 docs/tech-designs/10-query-editor.md §10。
    static func leadingKeyword(tokens: [SQLToken], text: String) -> String? {
        var depth = 0
        var sawLeadingWith = false
        var sawFirstKeyword = false

        for token in tokens {
            if token.kind == .punctuation {
                let symbol = SQLLexer.text(of: token, in: text)
                if symbol == "(" { depth += 1 }
                else if symbol == ")" { depth = max(0, depth - 1) }
                continue
            }
            guard token.kind == .keyword else { continue }
            let keyword = SQLLexer.text(of: token, in: text).uppercased()
            if !sawFirstKeyword {
                sawFirstKeyword = true
                if keyword == "WITH" {
                    sawLeadingWith = true
                    continue
                }
                return keyword
            }
            // WITH 模式下，只看括号深度为 0 的主语句关键字，跳过 AS / cte 名 / 列别名
            if sawLeadingWith, depth == 0, mainStatementKeywords.contains(keyword) {
                return keyword
            }
        }
        return nil
    }

    /// CTE 之后可以接的主语句关键字（用于 `WITH ... <主语句>` 判定）。
    private static let mainStatementKeywords: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE",
    ]

    // MARK: 字符分类

    private static func scanQuoted(_ units: [UInt16], from start: Int, quote: UInt16) -> Int {
        let n = units.count
        var i = start + 1
        while i < n {
            let c = units[i]
            if c == .backslash {
                i += 2
                continue
            }
            if c == quote {
                // `''` / `""` 双写转义
                if i + 1 < n, units[i + 1] == quote { i += 2; continue }
                return i + 1
            }
            i += 1
        }
        return n
    }

    private static func scanBacktick(_ units: [UInt16], from start: Int) -> Int {
        let n = units.count
        var i = start + 1
        while i < n {
            if units[i] == .backtick {
                if i + 1 < n, units[i + 1] == .backtick { i += 2; continue }
                return i + 1
            }
            i += 1
        }
        return n
    }

    private static func scanNumber(_ units: [UInt16], from start: Int) -> Int {
        let n = units.count
        var i = start
        // 0x / 0X 十六进制
        if units[i] == .zero, i + 1 < n, units[i + 1] == .x || units[i + 1] == .capitalX {
            i += 2
            while i < n, isHexDigit(units[i]) { i += 1 }
            return i
        }
        // 0b / 0B 二进制
        if units[i] == .zero, i + 1 < n, units[i + 1] == .b || units[i + 1] == .capitalB {
            i += 2
            while i < n, units[i] == .zero || units[i] == .one { i += 1 }
            return i
        }
        while i < n, isDigit(units[i]) { i += 1 }
        if i < n, units[i] == .dot {
            i += 1
            while i < n, isDigit(units[i]) { i += 1 }
        }
        if i < n, units[i] == .e || units[i] == .capitalE {
            var k = i + 1
            if k < n, units[k] == .plus || units[k] == .minus { k += 1 }
            if k < n, isDigit(units[k]) {
                i = k
                while i < n, isDigit(units[i]) { i += 1 }
            }
        }
        return i
    }

    private static func followedByOpenParen(_ units: [UInt16], from start: Int) -> Bool {
        var i = start
        while i < units.count, isWhitespace(units[i]) { i += 1 }
        return i < units.count && units[i] == .openParen
    }

    private static func operatorLength(_ units: [UInt16], at i: Int) -> Int? {
        func unit(_ k: Int) -> UInt16? { k < units.count ? units[k] : nil }
        switch units[i] {
        case .lessThan:
            if unit(i + 1) == .equal, unit(i + 2) == .greaterThan { return 3 } // <=>
            if unit(i + 1) == .equal { return 2 }                             // <=
            if unit(i + 1) == .lessThan { return 2 }                          // <<
            if unit(i + 1) == .greaterThan { return 2 }                       // <>
            return 1
        case .greaterThan:
            if unit(i + 1) == .equal { return 2 }                             // >=
            if unit(i + 1) == .greaterThan { return 2 }                       // >>
            return 1
        case .equal:
            return 1
        case .exclamation:
            if unit(i + 1) == .equal { return 2 }                             // !=
            return 1
        case .colon:
            if unit(i + 1) == .equal { return 2 }                             // :=
            return 1
        case .minus:
            if unit(i + 1) == .greaterThan, unit(i + 2) == .greaterThan { return 3 } // ->>
            if unit(i + 1) == .greaterThan { return 2 }                       // ->
            return 1
        case .ampersand:
            if unit(i + 1) == .ampersand { return 2 }                         // &&
            return 1
        case .pipe:
            if unit(i + 1) == .pipe { return 2 }                              // ||
            return 1
        case .plus, .star, .slash, .percent, .caret, .tilde:
            return 1
        default:
            return nil
        }
    }

    private static func classifyWord(_ word: String, followedByParen: Bool) -> SQLTokenKind {
        let upper = word.uppercased()
        if keywords.contains(upper) { return .keyword }
        if types.contains(upper) { return .type }
        if functions.contains(upper) { return .function }
        // 未知单词后紧跟 `(` → 按函数名着色（例如用户自定义函数）
        if followedByParen { return .function }
        return .identifier
    }

    private static func isWhitespace(_ c: UInt16) -> Bool {
        c == .space || c == .tab || c == .newline || c == .carriageReturn
            || c == .formFeed || c == .verticalTab
    }

    /// `--` 后允许的字符：空白或控制字符。
    private static func isCommentFollow(_ c: UInt16) -> Bool {
        c <= 0x20
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isHexDigit(_ c: UInt16) -> Bool {
        isDigit(c)
            || (c >= 0x41 && c <= 0x46)
            || (c >= 0x61 && c <= 0x66)
    }

    private static func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || c == .underscore || c == .dollar || c >= 0x80
    }

    private static func isIdentifierPart(_ c: UInt16) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    private static func isVariableChar(_ c: UInt16) -> Bool {
        isIdentifierPart(c) || c == .dot
    }

    private static func isPunctuation(_ c: UInt16) -> Bool {
        c == .openParen || c == .closeParen || c == .comma || c == .semicolon || c == .dot
    }

    // MARK: 关键字 / 类型 / 函数表

    private static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "DELETE",
        "REPLACE", "MERGE", "SET", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "ASC",
        "USE", "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "TABLE", "INDEX",
        "VIEW", "DATABASE", "SCHEMA", "PROCEDURE", "FUNCTION", "TRIGGER", "EVENT",
        "IF", "ELSE", "ELSEIF", "THEN", "CASE", "WHEN", "END", "BEGIN", "COMMIT",
        "ROLLBACK", "START", "TRANSACTION", "SAVEPOINT", "RELEASE", "LOCK", "UNLOCK",
        "GRANT", "REVOKE", "LOAD", "DATA", "CALL", "WITH", "RECURSIVE", "AS",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL", "ON",
        "USING", "GROUP", "BY", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION", "ALL",
        "DISTINCT", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN",
        "EXISTS", "ANY", "SOME", "INTERVAL", "PRIMARY", "KEY", "FOREIGN",
        "REFERENCES", "UNIQUE", "CHECK", "DEFAULT", "AUTO_INCREMENT", "CONSTRAINT",
        "CASCADE", "RESTRICT", "NO", "ACTION", "ADD", "COLUMN", "MODIFY", "CHANGE",
        "ENGINE", "CHARSET", "CHARACTER", "COLLATE", "COMMENT", "TEMPORARY",
        "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME", "OVER", "PARTITION",
        "WINDOW", "RETURNING", "DUPLICATE", "IGNORE", "FORCE", "STRAIGHT_JOIN",
        "DIV", "MOD", "XOR", "TRUE", "FALSE", "UNKNOWN", "ESCAPE", "ISNULL",
        "FOR", "OF", "TO", "BY", "ANALYZE", "OPTIMIZE", "REPAIR", "FLUSH", "RESET",
        "PURGE", "KILL", "PROCESSLIST", "STATUS", "VARIABLES", "ENGINES", "PLUGINS",
        "WARNINGS", "ERRORS", "GRANTS", "TRIGGERS", "TABLES", "COLUMNS",
    ]

    private static let types: Set<String> = [
        "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT", "DECIMAL",
        "NUMERIC", "FLOAT", "DOUBLE", "REAL", "BIT", "BOOL", "BOOLEAN", "SERIAL",
        "CHAR", "VARCHAR", "BINARY", "VARBINARY", "TINYTEXT", "TEXT", "MEDIUMTEXT",
        "LONGTEXT", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB", "DATE", "TIME",
        "DATETIME", "TIMESTAMP", "YEAR", "JSON", "ENUM", "GEOMETRY", "POINT",
        "LINESTRING", "POLYGON", "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON",
        "GEOMETRYCOLLECTION",
    ]

    private static let functions: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL", "NULLIF", "NOW",
        "CURDATE", "CURTIME", "UNIX_TIMESTAMP", "FROM_UNIXTIME", "DATE_FORMAT",
        "DATE_ADD", "DATE_SUB", "DATEDIFF", "TIMESTAMPDIFF", "STR_TO_DATE",
        "CONCAT", "CONCAT_WS", "SUBSTRING", "SUBSTR", "MID", "LENGTH",
        "CHAR_LENGTH", "CHARACTER_LENGTH", "UPPER", "LOWER", "UCASE", "LCASE",
        "TRIM", "LTRIM", "RTRIM", "LPAD", "RPAD", "INSTR", "LOCATE", "REPEAT",
        "REVERSE", "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "POW", "POWER",
        "SQRT", "RAND", "SIGN", "GREATEST", "LEAST", "CAST", "CONVERT",
        "JSON_EXTRACT", "JSON_UNQUOTE", "JSON_OBJECT", "JSON_ARRAY", "JSON_SET",
        "JSON_REMOVE", "JSON_CONTAINS", "JSON_LENGTH", "JSON_KEYS", "GROUP_CONCAT",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE", "LAG", "LEAD", "FIRST_VALUE",
        "LAST_VALUE", "NTH_VALUE", "LAST_INSERT_ID", "ROW_COUNT", "VERSION", "USER",
        "CONNECTION_ID", "UUID", "SLEEP", "BENCHMARK", "MD5", "SHA1", "SHA2", "HEX",
        "UNHEX", "BIN", "OCT", "FORMAT", "EXP", "LN", "LOG", "LOG2", "LOG10",
        "DEGREES", "RADIANS", "PI", "ATAN", "ATAN2", "COS", "SIN", "TAN", "ACOS",
        "ASIN",
    ]
}

// MARK: - 字符常量

private extension UInt16 {
    static let tab: UInt16 = 0x09
    static let newline: UInt16 = 0x0A
    static let verticalTab: UInt16 = 0x0B
    static let formFeed: UInt16 = 0x0C
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let exclamation: UInt16 = 0x21
    static let doubleQuote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let dollar: UInt16 = 0x24
    static let percent: UInt16 = 0x25
    static let ampersand: UInt16 = 0x26
    static let singleQuote: UInt16 = 0x27
    static let openParen: UInt16 = 0x28
    static let closeParen: UInt16 = 0x29
    static let star: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let comma: UInt16 = 0x2C
    static let minus: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let zero: UInt16 = 0x30
    static let one: UInt16 = 0x31
    static let colon: UInt16 = 0x3A
    static let semicolon: UInt16 = 0x3B
    static let lessThan: UInt16 = 0x3C
    static let equal: UInt16 = 0x3D
    static let greaterThan: UInt16 = 0x3E
    static let questionMark: UInt16 = 0x3F
    static let at: UInt16 = 0x40
    static let capitalB: UInt16 = 0x42
    static let capitalE: UInt16 = 0x45
    static let capitalX: UInt16 = 0x58
    static let backslash: UInt16 = 0x5C
    static let caret: UInt16 = 0x5E
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let b: UInt16 = 0x62
    static let e: UInt16 = 0x65
    static let x: UInt16 = 0x78
    static let pipe: UInt16 = 0x7C
    static let tilde: UInt16 = 0x7E
}
