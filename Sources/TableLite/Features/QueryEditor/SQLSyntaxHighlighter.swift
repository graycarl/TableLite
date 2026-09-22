import AppKit

/// SQL 语法高亮的增量着色器（`docs/tech-designs/10-query-editor.md` §3）。
///
/// 策略：
/// - 缓存上次的 token 与「检查点」（每个顶层 `;` 的结束位置）；
/// - 文本变化时找公共前缀，从**不大于改动起点的最近检查点**重新扫描到文末；
///   检查点之前的 token 原样复用 —— `;` 只会在字符串 / 注释之外产生，
///   因此它是无歧义的重扫起点，改动起点之后的重扫不会受影响；
/// - 属性只应用到 `[safeStart, end)`，改动之前的部分由 `NSTextStorage` 自动平移。
///
/// 这样常见编辑（改一个词）只重扫该语句之后的内容，不做全文重扫。
@MainActor
final class SQLSyntaxHighlighter {

    private(set) var tokens: [SQLToken] = []
    private var cachedText = ""
    private var checkpoints: [Int] = [0]
    private var lastStatementRange = NSRange(location: 0, length: 0)

    /// 清空缓存（换文本 / 打开文件时）。
    func invalidate() {
        tokens = []
        cachedText = ""
        checkpoints = [0]
        lastStatementRange = NSRange(location: 0, length: 0)
    }

    /// 增量计算 token；返回需要重新着色的起点。
    @discardableResult
    func refresh(text: String) -> Int {
        if cachedText == text {
            return text.utf16.count
        }

        let oldUnits = Array(cachedText.utf16)
        let newUnits = Array(text.utf16)

        var prefix = 0
        let shared = min(oldUnits.count, newUnits.count)
        while prefix < shared, oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        var safeStart = 0
        for checkpoint in checkpoints where checkpoint <= prefix {
            safeStart = max(safeStart, checkpoint)
        }
        // 改动可能删掉了原来的检查点；`safeStart` 仍指向未改动区域里合法的 `;` 结束处。
        if safeStart > newUnits.count { safeStart = 0 }

        var reused = tokens.filter { $0.range.endLocation <= safeStart }
        // 若改动起点落在复用区间内（理论上不会，因为 safeStart <= prefix），保守起见整体重扫。
        if reused.contains(where: { $0.range.endLocation > prefix }) {
            safeStart = 0
            reused = []
        }

        let tail = String(decoding: newUnits[safeStart...], as: UTF16.self)
        let tailTokens = SQLLexer.tokenize(tail).map { token in
            SQLToken(
                kind: token.kind,
                text: token.text,
                range: TextRange(
                    location: token.range.location + safeStart,
                    length: token.range.length
                )
            )
        }

        tokens = reused + tailTokens
        cachedText = text
        checkpoints = [0] + SQLStatementRangeLocator.boundaries(in: tokens)
        return safeStart
    }

    /// 把语法配色应用到文本存储的 `[start, end)`；`enabled` 为 false 时只设基础字体与前景色。
    func applySyntax(to textStorage: NSTextStorage, from start: Int, font: NSFont, enabled: Bool = true) {
        let length = textStorage.length
        guard start < length else { return }
        let range = NSRange(location: start, length: length - start)
        textStorage.beginEditing()
        textStorage.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: range)
        guard enabled else {
            textStorage.endEditing()
            return
        }
        for token in tokens where token.range.endLocation > start {
            let location = max(token.range.location, start)
            let tokenRange = NSRange(
                location: location,
                length: token.range.endLocation - location
            )
            guard tokenRange.length > 0, tokenRange.location + tokenRange.length <= length else { continue }
            textStorage.addAttribute(
                .foregroundColor,
                value: SQLHighlightTheme.color(for: token.kind),
                range: tokenRange
            )
        }
        textStorage.endEditing()
    }

    /// 重画「当前语句」背景。
    func applyStatementHighlight(
        to textStorage: NSTextStorage,
        textLength: Int,
        cursor: Int,
        enabled: Bool
    ) {
        textStorage.beginEditing()
        if lastStatementRange.length > 0,
           lastStatementRange.location + lastStatementRange.length <= textStorage.length {
            textStorage.removeAttribute(.backgroundColor, range: lastStatementRange)
        }
        lastStatementRange = NSRange(location: 0, length: 0)

        if enabled, let range = SQLStatementRangeLocator.statementRange(in: tokens, textLength: textLength, cursor: cursor) {
            let nsRange = NSRange(location: range.location, length: range.length)
            if nsRange.length > 0, NSMaxRange(nsRange) <= textStorage.length {
                textStorage.addAttribute(.backgroundColor, value: SQLHighlightTheme.statementBackground, range: nsRange)
                lastStatementRange = nsRange
            }
        }
        textStorage.endEditing()
    }

    /// 当前语句范围（供行号栏标记起始行）。
    var statementRange: TextRange? {
        lastStatementRange.length > 0
            ? TextRange(location: lastStatementRange.location, length: lastStatementRange.length)
            : nil
    }
}
