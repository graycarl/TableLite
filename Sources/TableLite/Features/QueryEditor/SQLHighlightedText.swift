import SwiftUI
import AppKit

/// SwiftUI 侧的语法高亮文本（L30：预览 SQL 面板）。
///
/// 复用 `SQLLexer` 的 token 分类，把颜色写进 `AttributedString`；
/// 比嵌一个 `SQLTextView` 更轻，适合在列表里逐条渲染。
struct SQLHighlightedText: View {

    let sql: String
    var font: Font = .system(.body, design: .monospaced)

    var body: some View {
        Text(Self.make(sql))
            .font(font)
    }

    @MainActor
    static func make(_ sql: String) -> AttributedString {
        var result = AttributedString()
        let nsText = sql as NSString
        var cursor = 0
        for token in SQLLexer.tokenize(sql) {
            if token.range.location > cursor {
                let gap = nsText.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
                result += AttributedString(gap)
            }
            var piece = AttributedString(token.text)
            piece.foregroundColor = Color(nsColor: SQLHighlightTheme.color(for: token.kind))
            result += piece
            cursor = token.range.endLocation
        }
        if cursor < nsText.length {
            result += AttributedString(nsText.substring(from: cursor))
        }
        return result
    }
}
