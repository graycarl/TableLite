import Foundation

/// 一条拆分出来的语句。
///
/// - `text` 保留原始内容（含结尾分号），下发时不再补分号；
/// - `range` 是它在原文里的 UTF-16 范围，供「当前语句高亮」使用。
public struct SQLStatement: Sendable, Equatable, Hashable {
    public var text: String
    public var range: TextRange
    public var kind: SQLStatementKind

    public init(text: String, range: TextRange, kind: SQLStatementKind) {
        self.text = text
        self.range = range
        self.kind = kind
    }
}

/// 语句拆分器。
///
/// 规则见 `docs/tech-designs/10-query-editor.md` §4：
/// - 分号分隔，但忽略字符串 / 反引号 / 注释内的分号；
/// - 结尾没有分号的最后一段（非空）也算一条；
/// - 空语句 / 纯注释段跳过；
/// - 保留原始内容（含结尾分号）。
public enum StatementSplitter {
    public static func split(_ sql: String) -> [SQLStatement] {
        let units = Array(sql.utf16)
        let tokens = SQLLexer.tokenize(sql)

        // 只认真正的分号 token：字符串 / 注释里的分号已经被并入对应 token。
        var boundaries: [Int] = []
        for token in tokens where token.kind == .punctuation && token.text == ";" {
            boundaries.append(token.range.endLocation)
        }
        boundaries.append(units.count)

        var statements: [SQLStatement] = []
        var cursor = 0
        for boundary in boundaries {
            if let statement = makeStatement(units: units, tokens: tokens, from: cursor, to: boundary) {
                statements.append(statement)
            }
            cursor = boundary
        }
        return statements
    }

    private static func makeStatement(
        units: [UInt16],
        tokens: [SQLToken],
        from: Int,
        to: Int
    ) -> SQLStatement? {
        var start = from
        var end = to
        while start < end, SQLLexer.isWhitespace(units[start]) { start += 1 }
        while end > start, SQLLexer.isWhitespace(units[end - 1]) { end -= 1 }
        guard start < end else { return nil }

        // 纯注释 / 空语句段跳过：范围内没有任何「有内容」的 token 就不算语句。
        // 单独一个分号（`;`）属于空语句，也要排除。
        let hasContent = tokens.contains { token in
            guard token.kind != .comment else { return false }
            if token.kind == .punctuation && token.text == ";" { return false }
            return token.range.location >= start && token.range.location < end
        }
        guard hasContent else { return nil }

        let text = String(decoding: units[start..<end], as: UTF16.self)
        return SQLStatement(
            text: text,
            range: TextRange(location: start, length: end - start),
            kind: SQLStatementClassifier.classify(text)
        )
    }
}
