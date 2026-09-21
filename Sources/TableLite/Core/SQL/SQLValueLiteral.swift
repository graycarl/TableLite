import Foundation

/// 字符串字面量的转义模式。
///
/// - `mysqlDefault`：默认 `sql_mode`，反斜杠是转义符。
/// - `noBackslashEscapes`：`NO_BACKSLASH_ESCAPES`，反斜杠是普通字符，只把单引号双写。
///
/// 真实连接会用 `mysql_real_escape_string`（见 `docs/tech-designs/03-mysql-layer.md` §1、
/// §4.2），那一路由 MySQL 层通过本类型的 `quote(_:escaper:)` 注入转义结果；这里提供纯函数
/// 实现是为了单测与 Preview 的确定性。
public enum SQLStringEscaping: Sendable, Equatable, Hashable {
    case mysqlDefault
    case noBackslashEscapes
}

/// 生成 MySQL 字面量的纯函数集合。
///
/// 规则严格按 `docs/tech-designs/03-mysql-layer.md` §4.2：
/// - `NULL` → `NULL`；
/// - 字符串 → 单引号 + 转义；
/// - 二进制 → `0x` + 大写 hex，空串为 `X''`；
/// - 数字列 → 仅当文本匹配严格正则 `^-?\d+$` / `^-?\d+\.\d+$` 时才去引号；
/// - 任何无法确定的情况一律走字符串字面量。
public enum SQLValueLiteral {
    /// 自定义转义函数（真实连接用 `mtl_conn_escape` 的结果）。
    public typealias StringEscaper = @Sendable (_ input: String) -> String

    // MARK: 主入口

    /// 按列类型生成字面量。
    public static func literal(
        for value: SQLValue,
        column: ColumnInfo,
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil
    ) -> String {
        literal(
            for: value,
            fieldType: column.fieldType,
            isBinaryColumn: column.isBinary,
            escaping: escaping,
            introducer: introducer
        )
    }

    /// 按字段类型生成字面量。主入口。
    public static func literal(
        for value: SQLValue,
        fieldType: MySQLFieldType,
        isBinaryColumn: Bool = false,
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil
    ) -> String {
        switch value {
        case .null:
            return "NULL"

        case .binary(let data):
            // 二进制一律走 hex，完全不经过转义路径。
            return hexLiteral(data)

        case .bool(let flag):
            return flag ? "1" : "0"

        case .integer(let number):
            return String(number)

        case .decimal(let text):
            return isStrictDecimal(text) ? text : quoted(text, escaping: escaping, introducer: introducer)

        case .text(let text):
            // 数字列且文本通过严格数字正则时才去引号；其余一律走字符串字面量。
            // 注意：charset 为 binary 的字符串列不应因此被当作数字，这里不看 isBinaryColumn。
            if fieldType.isNumeric, isStrictNumber(text) {
                return text
            }
            return quoted(text, escaping: escaping, introducer: introducer)
        }
    }

    /// 用外部转义函数（真实连接）生成字符串字面量。
    public static func literal(
        for text: String,
        escaper: StringEscaper,
        introducer: String? = nil
    ) -> String {
        quote(text, escaper: escaper, introducer: introducer)
    }

    // MARK: 拼接

    /// 单引号字符串，内部按模式转义。
    public static func quoted(
        _ text: String,
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil
    ) -> String {
        quote(text, escaper: { escape($0, mode: escaping) }, introducer: introducer)
    }

    /// 单引号字符串，转义由调用方提供。
    public static func quote(
        _ text: String,
        escaper: StringEscaper,
        introducer: String? = nil
    ) -> String {
        "\(introducer ?? "")'\(escaper(text))'"
    }

    /// `0x…` 十六进制字面量；空数据为 `X''`。
    public static func hexLiteral(_ data: Data) -> String {
        if data.isEmpty { return "X''" }
        return "0x" + data.hexString
    }

    /// 由 `mtl_conn_escape` 风格已经转义好的文本（不含首尾引号）拼出字符串字面量。
    public static func quotedPreEscaped(_ escapedText: String, introducer: String? = nil) -> String {
        "\(introducer ?? "")'\(escapedText)'"
    }

    // MARK: 转义

    /// 纯 Swift 的转义实现，对应默认 `sql_mode` 与 `NO_BACKSLASH_ESCAPES`。
    public static func escape(_ text: String, mode: SQLStringEscaping = .mysqlDefault) -> String {
        switch mode {
        case .noBackslashEscapes:
            // 只有单引号需要双写。
            return text.replacingOccurrences(of: "'", with: "''")

        case .mysqlDefault:
            var result = ""
            result.reserveCapacity(text.utf8.count)
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\0": result += "\\0"
                case "\n": result += "\\n"
                case "\r": result += "\\r"
                case "\\": result += "\\\\"
                case "'": result += "\\'"
                case "\"": result += "\\\""
                case "\u{1A}": result += "\\Z"
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result
        }
    }

    // MARK: 严格数字

    /// 严格整数：`^-?\d+$`。不允许 `1e5`、`0x1`、前导 `+`、空白。
    public static func isStrictInteger(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var index = text.startIndex
        if text[index] == "-" {
            index = text.index(after: index)
            if index == text.endIndex { return false }
        }
        while index < text.endIndex {
            guard text[index].isASCII, text[index].isNumber else { return false }
            index = text.index(after: index)
        }
        return true
    }

    /// 严格小数：`^-?\d+\.\d+$`。
    public static func isStrictDecimal(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var index = text.startIndex
        if text[index] == "-" {
            index = text.index(after: index)
            if index == text.endIndex { return false }
        }
        var digitCount = 0
        while index < text.endIndex, text[index].isASCII, text[index].isNumber {
            index = text.index(after: index)
            digitCount += 1
        }
        guard digitCount > 0, index < text.endIndex, text[index] == "." else { return false }
        index = text.index(after: index)
        var fractionCount = 0
        while index < text.endIndex, text[index].isASCII, text[index].isNumber {
            index = text.index(after: index)
            fractionCount += 1
        }
        return fractionCount > 0 && index == text.endIndex
    }

    /// 严格整数或小数。
    public static func isStrictNumber(_ text: String) -> Bool {
        isStrictInteger(text) || isStrictDecimal(text)
    }

    // MARK: introducer

    /// 连接 charset 非 utf8 系时返回引入符（如 `_latin1`），否则返回 nil。
    ///
    /// 见 `docs/tech-designs/03-mysql-layer.md` §4.2。
    public static func charsetIntroducer(for charset: String) -> String? {
        let normalized = charset.lowercased()
        if normalized.hasPrefix("utf8") || normalized.hasPrefix("utf-8") {
            return nil
        }
        return "_\(normalized)"
    }
}
