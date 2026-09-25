import AppKit

/// 语法高亮配色（`docs/tech-designs/10-query-editor.md` §3、`specs/06-query-editor.md` §2）。
///
/// 跟随系统深浅色：一律使用 AppKit 语义色 / 动态系统色，不写死亮色值，
/// 也不引入自定义主题（`docs/tech-designs/06-ui-layer.md` §9、S40）。
/// 颜色不驻留为静态属性（`NSColor` 非 `Sendable`），每次在 `@MainActor` 上按需取。
@MainActor
enum SQLHighlightTheme {

    static func color(for kind: SQLTokenKind) -> NSColor {
        switch kind {
        case .keyword: return .systemPurple
        case .function: return .systemBlue
        case .type: return .systemIndigo
        case .string: return .systemRed
        case .quotedIdentifier: return .systemBrown
        case .number: return .systemTeal
        case .comment: return .secondaryLabelColor
        case .variable: return .systemOrange
        case .parameter: return .systemPurple
        case .operatorSymbol, .punctuation: return .labelColor
        case .identifier: return .labelColor
        }
    }

    /// 当前光标所在语句整段背景（`specs/06-query-editor.md` §2）。
    static var statementBackground: NSColor {
        NSColor.controlAccentColor.withDynamicAlpha(0.10)
    }
}
