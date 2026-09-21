import Foundation

// MARK: - SQL 值字面量生成
//
// 规则见 docs/tech-designs/03-mysql-layer.md §4.2：
// - `NULL` → `NULL`
// - 二进制列（`kind.isBinaryLike` 或值不是合法 UTF-8）→ `0x` + 大写 hex；空为 `X''`
// - 数字列 → 严格正则 `^-?\d+$` 或 `^-?\d+\.\d+$` 才去引号；否则带引号
// - 其它 → `'转义结果'`，`literalizer.needsIntroducer` 时前缀 `_charset`
//
// 硬约束：**永不拼接未验证的内容**；转义一律交给 `literalizer.escape`
//（真实连接上由 `mysql_real_escape_string` 实现）。

enum SQLValueLiteral {

    /// 生成单个值的 SQL 字面量。
    static func literal(_ value: CellValue, kind: ColumnKind, using literalizer: SQLValueLiteralizer) -> String {
        switch value {
        case .null:
            return "NULL"

        case .bytes(let bytes):
            // 二进制家族：完全不经过转义路径
            if kind.isBinaryLike {
                return hexLiteral(bytes)
            }
            // 值本身不是合法 UTF-8 → 按二进制处理，避免损坏数据
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                return hexLiteral(bytes)
            }
            // 数字列且通过严格正则才去引号
            if kind.isNumeric, isStrictNumeric(text) {
                return text
            }
            return stringLiteral(text, using: literalizer)
        }
    }

    /// `0x` + 大写 hex；空字节串为 `X''`。
    static func hexLiteral(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "X''" }
        return "0x" + bytes.map(hexByte).joined()
    }

    /// 严格数字正则：`^-?\d+$` 或 `^-?\d+\.\d+$`。
    ///
    /// 刻意拒绝 `1e5`、`0x1`、前导 `+`、首尾空白、`1.`、`.5` 等，避免把非数字原样拼进 SQL。
    static func isStrictNumeric(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return false }

        var i = 0
        if bytes[0] == 0x2D { i += 1 } // '-'
        var integerDigits = 0
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            i += 1; integerDigits += 1
        }
        guard integerDigits > 0 else { return false }
        if i == bytes.count { return true }

        guard bytes[i] == 0x2E else { return false } // '.'
        i += 1
        var fractionDigits = 0
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            i += 1; fractionDigits += 1
        }
        guard fractionDigits > 0 else { return false }
        return i == bytes.count
    }

    // MARK: 内部

    private static func stringLiteral(_ text: String, using literalizer: SQLValueLiteralizer) -> String {
        let escaped = literalizer.escape(text)
        if literalizer.needsIntroducer {
            return "_\(literalizer.charsetName)'\(escaped)'"
        }
        return "'\(escaped)'"
    }

    /// 单个字节 → 两位大写 hex。
    private static func hexByte(_ byte: UInt8) -> String {
        let hex = String(byte, radix: 16, uppercase: true)
        return hex.count == 1 ? "0" + hex : hex
    }
}
