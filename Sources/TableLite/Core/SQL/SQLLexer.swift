import Foundation

// MARK: - 源码范围

/// 以 UTF-16 偏移表示的范围，和 `NSRange` 一致，直接供 `NSTextView` 高亮使用。
public struct TextRange: Sendable, Equatable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var endLocation: Int { location + length }

    public var isEmpty: Bool { length == 0 }
}

// MARK: - Token

/// 高亮 token 的分类。见 `docs/tech-designs/10-query-editor.md` §3。
public enum SQLTokenKind: String, Sendable, Codable, CaseIterable, Hashable {
    case keyword
    case function
    case type
    case string
    case quotedIdentifier
    case number
    case comment
    case variable
    case parameter
    case operatorSymbol
    case punctuation
    case identifier
}

public struct SQLToken: Sendable, Equatable, Hashable {
    public var kind: SQLTokenKind
    public var text: String
    public var range: TextRange

    public init(kind: SQLTokenKind, text: String, range: TextRange) {
        self.kind = kind
        self.text = text
        self.range = range
    }
}

// MARK: - 词法扫描器

/// 手写单向扫描器，输出 `(range, token)`。纯函数，不依赖任何连接。
///
/// 必须正确处理：字符串内的 `--` 与 `;`、`''` / `\'` / `""` / `\"` 转义、反引号内任意内容、
/// `/*! … */` 版本注释、`#` 注释。见 `docs/tech-designs/10-query-editor.md` §3。
public enum SQLLexer {
    public static func tokenize(_ sql: String) -> [SQLToken] {
        let units = Array(sql.utf16)
        var tokens: [SQLToken] = []
        var index = 0
        while index < units.count {
            let unit = units[index]

            // 空白
            if isWhitespace(unit) {
                index += 1
                continue
            }

            // 行注释：`#` 或 `-- `（`--` 后必须是空白 / 控制字符或行尾）
            if unit == 0x23 || (unit == 0x2D && isDashCommentStart(units, at: index)) {
                let end = scanToLineEnd(units, from: index)
                tokens.append(makeToken(.comment, units, index, end))
                index = end
                continue
            }

            // 块注释：`/* … */`（含 `/*! … */` 版本注释）
            if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2A {
                let end = scanBlockComment(units, from: index)
                tokens.append(makeToken(.comment, units, index, end))
                index = end
                continue
            }

            // 字符串：单引号 / 双引号
            if unit == 0x27 || unit == 0x22 {
                let end = scanQuoted(units, from: index, quote: unit)
                tokens.append(makeToken(.string, units, index, end))
                index = end
                continue
            }

            // 反引号标识符
            if unit == 0x60 {
                let end = scanBacktick(units, from: index)
                tokens.append(makeToken(.quotedIdentifier, units, index, end))
                index = end
                continue
            }

            // 变量：@foo / @@global.foo
            if unit == 0x40 {
                var end = index + 1
                if end < units.count, units[end] == 0x40 { end += 1 }
                while end < units.count, isIdentifierPart(units[end]) || units[end] == 0x2E {
                    end += 1
                }
                tokens.append(makeToken(.variable, units, index, end))
                index = end
                continue
            }

            // 参数占位符
            if unit == 0x3F {
                tokens.append(makeToken(.parameter, units, index, index + 1))
                index += 1
                continue
            }

            // 数字
            if isDigit(unit) || (unit == 0x2E && index + 1 < units.count && isDigit(units[index + 1])) {
                let end = scanNumber(units, from: index)
                tokens.append(makeToken(.number, units, index, end))
                index = end
                continue
            }

            // 标识符 / 关键字 / 函数 / 类型
            if isIdentifierStart(unit) {
                var end = index + 1
                while end < units.count, isIdentifierPart(units[end]) {
                    end += 1
                }
                let word = decode(units, index, end)
                let upper = word.uppercased()
                let kind: SQLTokenKind
                if isFunctionCall(units, from: end), functionNames.contains(upper) {
                    kind = .function
                } else if typeNames.contains(upper) {
                    kind = .type
                } else if keywordNames.contains(upper) {
                    kind = .keyword
                } else {
                    kind = .identifier
                }
                tokens.append(SQLToken(kind: kind, text: word, range: TextRange(location: index, length: end - index)))
                index = end
                continue
            }

            // 标点
            if unit == 0x28 || unit == 0x29 || unit == 0x2C || unit == 0x3B || unit == 0x2E {
                tokens.append(makeToken(.punctuation, units, index, index + 1))
                index += 1
                continue
            }

            // 运算符（三字符 → 两字符 → 单字符）
            if let length = operatorLength(units, at: index) {
                tokens.append(makeToken(.operatorSymbol, units, index, index + length))
                index += length
                continue
            }

            // 兜底：单个字符当标识符，保证扫描器一定前进。
            tokens.append(makeToken(.identifier, units, index, index + 1))
            index += 1
        }
        return tokens
    }

    // MARK: 字符判定

    static func isWhitespace(_ unit: UInt16) -> Bool { unit <= 0x20 }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x61 && unit <= 0x7A)
            || unit == 0x5F || unit == 0x24 || unit >= 0x80
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    // MARK: 扫描

    /// `--` 注释要求后面是空白 / 控制字符或行尾。
    static func isDashCommentStart(_ units: [UInt16], at index: Int) -> Bool {
        guard index + 1 < units.count, units[index + 1] == 0x2D else { return false }
        let next = index + 2
        if next >= units.count { return true }
        return units[next] <= 0x20
    }

    static func scanToLineEnd(_ units: [UInt16], from index: Int) -> Int {
        var cursor = index
        while cursor < units.count, units[cursor] != 0x0A, units[cursor] != 0x0D {
            cursor += 1
        }
        return cursor
    }

    static func scanBlockComment(_ units: [UInt16], from index: Int) -> Int {
        var cursor = index + 2
        while cursor + 1 < units.count {
            if units[cursor] == 0x2A, units[cursor + 1] == 0x2F {
                return cursor + 2
            }
            cursor += 1
        }
        return units.count
    }

    /// 扫描引号字符串，兼容 `\x` 与 `''` 两种转义。
    static func scanQuoted(_ units: [UInt16], from index: Int, quote: UInt16) -> Int {
        var cursor = index + 1
        while cursor < units.count {
            let unit = units[cursor]
            if unit == 0x5C {
                cursor += 2
                continue
            }
            if unit == quote {
                if cursor + 1 < units.count, units[cursor + 1] == quote {
                    cursor += 2
                    continue
                }
                return cursor + 1
            }
            cursor += 1
        }
        return units.count
    }

    /// 反引号标识符：只有反引号双写是转义。
    static func scanBacktick(_ units: [UInt16], from index: Int) -> Int {
        var cursor = index + 1
        while cursor < units.count {
            if units[cursor] == 0x60 {
                if cursor + 1 < units.count, units[cursor + 1] == 0x60 {
                    cursor += 2
                    continue
                }
                return cursor + 1
            }
            cursor += 1
        }
        return units.count
    }

    static func scanNumber(_ units: [UInt16], from index: Int) -> Int {
        var cursor = index
        // 十六进制：0x / 0X
        if units[cursor] == 0x30, cursor + 1 < units.count, units[cursor + 1] == 0x78 || units[cursor + 1] == 0x58 {
            cursor += 2
            while cursor < units.count, isHexDigit(units[cursor]) { cursor += 1 }
            return cursor
        }
        while cursor < units.count, isDigit(units[cursor]) { cursor += 1 }
        if cursor < units.count, units[cursor] == 0x2E {
            cursor += 1
            while cursor < units.count, isDigit(units[cursor]) { cursor += 1 }
        }
        if cursor < units.count, units[cursor] == 0x65 || units[cursor] == 0x45 {
            var lookahead = cursor + 1
            if lookahead < units.count, units[lookahead] == 0x2B || units[lookahead] == 0x2D {
                lookahead += 1
            }
            if lookahead < units.count, isDigit(units[lookahead]) {
                cursor = lookahead
                while cursor < units.count, isDigit(units[cursor]) { cursor += 1 }
            }
        }
        return cursor
    }

    /// 若 `index` 处是运算符，返回其长度。注意 `/*` 已在前面单独处理。
    static func operatorLength(_ units: [UInt16], at index: Int) -> Int? {
        let first = units[index]
        if first == 0x3C, index + 2 < units.count,
           units[index + 1] == 0x3D, units[index + 2] == 0x3E { // <=>
            return 3
        }
        if index + 1 < units.count {
            let second = units[index + 1]
            let pair = (first, second)
            let twoChar: [(UInt16, UInt16)] = [
                (0x3C, 0x3D), // <=
                (0x3E, 0x3D), // >=
                (0x3C, 0x3E), // <>
                (0x21, 0x3D), // !=
                (0x3A, 0x3D), // :=
                (0x7C, 0x7C), // ||
                (0x26, 0x26), // &&
                (0x3C, 0x3C), // <<
                (0x3E, 0x3E), // >>
            ]
            if twoChar.contains(where: { $0.0 == pair.0 && $0.1 == pair.1 }) {
                return 2
            }
        }
        let singles: Set<UInt16> = [0x3D, 0x3C, 0x3E, 0x21, 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x26, 0x7C, 0x5E, 0x7E, 0x3A]
        return singles.contains(first) ? 1 : nil
    }

    /// 标识符后面紧接的（跳过空白）是否是 `(`。
    static func isFunctionCall(_ units: [UInt16], from index: Int) -> Bool {
        var cursor = index
        while cursor < units.count, isWhitespace(units[cursor]) { cursor += 1 }
        return cursor < units.count && units[cursor] == 0x28
    }

    // MARK: 辅助

    private static func decode(_ units: [UInt16], _ start: Int, _ end: Int) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
    }

    private static func makeToken(
        _ kind: SQLTokenKind,
        _ units: [UInt16],
        _ start: Int,
        _ end: Int
    ) -> SQLToken {
        SQLToken(
            kind: kind,
            text: decode(units, start, end),
            range: TextRange(location: start, length: end - start)
        )
    }
}

// MARK: - 关键字 / 函数 / 类型表

extension SQLLexer {
    static let functionNames: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT",
        "NOW", "CURDATE", "CURTIME", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME",
        "DATE", "TIME", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND",
        "DATE_FORMAT", "STR_TO_DATE", "UNIX_TIMESTAMP", "FROM_UNIXTIME",
        "COALESCE", "IFNULL", "NULLIF", "IF", "GREATEST", "LEAST",
        "CONCAT", "CONCAT_WS", "LENGTH", "CHAR_LENGTH", "OCTET_LENGTH",
        "SUBSTRING", "SUBSTR", "MID", "LEFT", "RIGHT", "TRIM", "LTRIM", "RTRIM",
        "UPPER", "LOWER", "UCASE", "LCASE", "REPLACE", "LOCATE", "INSTR", "POSITION",
        "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "TRUNCATE", "MOD", "POW", "POWER", "SQRT", "EXP", "LOG", "LN", "RAND",
        "CAST", "CONVERT",
        "JSON_EXTRACT", "JSON_OBJECT", "JSON_ARRAY", "JSON_LENGTH", "JSON_VALID", "JSON_UNQUOTE",
        "UUID", "DATABASE", "VERSION", "USER", "CURRENT_USER", "LAST_INSERT_ID", "FOUND_ROWS", "ROW_COUNT",
        "FORMAT", "HEX", "UNHEX", "MD5", "SHA1", "SHA2", "BIN", "OCT", "CONV",
    ]

    static let typeNames: Set<String> = [
        "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
        "INT1", "INT2", "INT3", "INT4", "INT8", "SERIAL",
        "DECIMAL", "NUMERIC", "DEC", "FIXED", "FLOAT", "DOUBLE", "REAL", "BIT",
        "BOOLEAN", "BOOL",
        "DATE", "DATETIME", "TIMESTAMP", "TIME", "YEAR",
        "CHAR", "VARCHAR", "BINARY", "VARBINARY", "NCHAR", "NVARCHAR",
        "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB",
        "TINYTEXT", "TEXT", "MEDIUMTEXT", "LONGTEXT",
        "ENUM", "SET", "JSON",
        "GEOMETRY", "POINT", "LINESTRING", "POLYGON",
        "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION",
        "UNSIGNED", "SIGNED", "ZEROFILL",
    ]

    static let keywordNames: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "REPLACE", "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "TABLE", "VIEW",
        "DATABASE", "SCHEMA", "INDEX", "KEY", "PRIMARY", "FOREIGN", "UNIQUE", "REFERENCES",
        "CONSTRAINT", "DEFAULT", "NULL", "NOT", "AND", "OR", "XOR", "IS", "IN", "BETWEEN",
        "LIKE", "ESCAPE", "REGEXP", "RLIKE", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END",
        "AS", "ON", "USING", "JOIN", "INNER", "OUTER", "LEFT", "RIGHT", "FULL", "CROSS",
        "NATURAL", "STRAIGHT_JOIN", "UNION", "ALL", "DISTINCT", "GROUP", "BY", "HAVING",
        "ORDER", "ASC", "DESC", "LIMIT", "OFFSET", "FOR", "UPDATE", "LOCK", "SHARE", "MODE",
        "WITH", "RECURSIVE", "ROLLUP", "WINDOW", "OVER", "PARTITION", "RANGE", "ROWS",
        "PRECEDING", "FOLLOWING", "CURRENT", "ROW", "UNBOUNDED",
        "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "USE", "CALL", "DO", "HANDLER",
        "GRANT", "REVOKE", "FLUSH", "OPTIMIZE", "ANALYZE", "CHECK", "REPAIR",
        "LOAD", "DATA", "INFILE", "OUTFILE", "DUPLICATE", "IGNORE",
        "IF", "ELSEIF", "WHILE", "REPEAT", "LOOP", "LEAVE", "ITERATE",
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "START", "TRANSACTION",
        "AUTO_INCREMENT", "COMMENT", "COLLATE", "CHARACTER", "CHARSET", "CONVERT",
        "ENGINE", "ROW_FORMAT", "TEMPORARY", "OR REPLACE", "DEFINER", "SQL", "SECURITY",
        "TRIGGER", "BEFORE", "AFTER", "EACH", "STATEMENT", "RETURNS", "RETURN",
        "PROCEDURE", "FUNCTION", "DELIMITER", "EVENT", "SCHEDULE", "EVERY",
        "ADD", "COLUMN", "CHANGE", "MODIFY", "RENAME", "TO", "CASCADE", "RESTRICT",
        "ACTION", "NO", "FULLTEXT", "SPATIAL", "BTREE", "HASH", "USING",
        "TRUE", "FALSE", "UNKNOWN", "INTERVAL", "EXTRACT", "DIV", "MOD",
        "OUT", "INOUT", "INTO", "SET", "DECLARE", "CURSOR", "FETCH", "OPEN", "CLOSE",
        "EXIT", "UNDO", "SQLSTATE", "RESIGNAL", "SIGNAL", "CONDITION",
        "LOCK", "UNLOCK", "TABLES", "WITH", "READ", "WRITE", "LOCAL", "GLOBAL", "SESSION",
        "VARIABLES", "STATUS", "PROCESSLIST", "ENGINES", "WARNINGS", "ERRORS",
        "PRIVILEGES", "COLUMNS", "INDEXES", "KEYS", "DATABASES", "SCHEMAS",
        "STORAGE", "ENFORCED", "VISIBLE", "INVISIBLE", "GENERATED", "ALWAYS", "VIRTUAL", "STORED",
        "FIELDS", "TERMINATED", "ENCLOSED", "OPTIONALLY", "LINES", "STARTING",
        "PARTITION", "SUBPARTITION", "PARTITIONS", "REORGANIZE", "EXCHANGE", "COALESCE",
        "SIGNED", "UNSIGNED", "ZEROFILL", "PRECISION", "VARYING", "NATIONAL",
        "FORCE", "USE", "IGNORE", "FORCE", "QUICK", "EXTENDED", "CHANGED",
        "NATURAL", "LOW_PRIORITY", "HIGH_PRIORITY", "DELAYED", "QUICK",
        "ALGORITHM", "INPLACE", "COPY", "INSTANT", "DEFAULT", "VIRTUAL",
        "MATCH", "AGAINST", "BOOLEAN", "QUERY", "EXPANSION",
        "JSON_TABLE", "JSON_VALUE", "JSON_QUERY",
        "EXCEPT", "INTERSECT", "RECURSIVE", "LATERAL",
        "CUBE", "GROUPING", "WITHIN",
        "APPLICATION", "PASSWORD", "IDENTIFIED", "ROLE", "USER",
        "TABLESPACE", "LOGFILE", "GENERAL", "SLOW", "BINARY", "RELAY",
        "MASTER", "SLAVE", "CHANNEL", "REPLICA", "SOURCE", "RESET", "PURGE",
    ]
}
