import Foundation

/// 由已 tokenize 的结果定位「光标所在语句」的整段范围。
///
/// 纯函数（`docs/tech-designs/10-query-editor.md` §3：当前语句高亮；§5.1：执行哪段）。
/// 高亮在每次按键时都要算，**不再重扫全文**：直接复用增量高亮缓存的 token。
public enum SQLStatementRangeLocator {

    /// 语句边界：顶层 `;` 的结束位置（token 只在字符串 / 注释之外产生分号）。
    public static func boundaries(in tokens: [SQLToken]) -> [Int] {
        tokens
            .filter { $0.kind == .punctuation && $0.text == ";" }
            .map { $0.range.endLocation }
    }

    /// 定位包含 `cursor`（UTF-16 偏移）的语句范围。
    ///
    /// - 光标恰好落在某个 `;` 之后时，算作下一条语句（与 `StatementSplitter` 一致）；
    /// - 前后空白被裁掉，高亮只覆盖语句本体；
    /// - 返回 `nil` 表示该段为空（纯空白 / 空文本）。
    public static func statementRange(in tokens: [SQLToken], textLength: Int, cursor: Int) -> TextRange? {
        guard textLength > 0 else { return nil }
        let clamped = min(max(cursor, 0), textLength)
        let bounds = boundaries(in: tokens)

        var start = 0
        var end = textLength
        for boundary in bounds {
            if boundary <= clamped {
                start = boundary
            } else {
                end = boundary
                break
            }
        }
        guard end > start else {
            // 光标正好在两个分号的交界（`;;` 之类），回退到前一段。
            if let previous = bounds.last(where: { $0 < end }) {
                start = previous
            }
            guard end > start else { return nil }
            return TextRange(location: start, length: end - start)
        }
        return trim(start: start, end: end, tokens: tokens)
    }

    /// 裁掉区间两端的空白：只取落在区间内 token 的最小起点到最大终点。
    private static func trim(start: Int, end: Int, tokens: [SQLToken]) -> TextRange? {
        let inside = tokens.filter { $0.range.location >= start && $0.range.endLocation <= end }
        guard let first = inside.first, let last = inside.last, last.range.endLocation > first.range.location else {
            return nil
        }
        return TextRange(location: first.range.location, length: last.range.endLocation - first.range.location)
    }
}
