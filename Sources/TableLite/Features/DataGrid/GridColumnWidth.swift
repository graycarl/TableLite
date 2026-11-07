import AppKit

/// 列宽自动适配（`specs/03-data-browsing.md` §5、`docs/tech-designs/07-data-grid.md` §4.1）。
///
/// 纯逻辑，可单测：给一批候选文本（表头 + 可见行的显示值）和网格字体，量出该列该有多宽。
/// 早先用的是「字符数 × 8pt」，中文字宽是 ASCII 的 1.6 倍，量出来必然偏窄，
/// 于是每列都被截成 `zhangsa…`。
enum GridColumnWidth {

    /// 再窄就没法读类型名与数字了。
    static let minimum: CGFloat = 60
    /// 兜底上限：一个字段再长也不让整列吃掉半屏。
    static let maximum: CGFloat = 400

    /// 单元格内边距：`GridCellView` 里文字左 5pt、右 4pt，外键箭头另有 4pt；
    /// 再加一点余量，值不会贴着竖线。
    static let cellPadding: CGFloat = 16

    /// - Parameters:
    ///   - texts: 候选文本，通常是列头 + 可见行的显示值（已按 `§4` 转成显示文本）。
    static func fit(
        texts: some Sequence<String>,
        font: NSFont,
        minimum: CGFloat = GridColumnWidth.minimum,
        maximum: CGFloat = GridColumnWidth.maximum
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for text in texts where !text.isEmpty {
            let width = (text as NSString).size(withAttributes: attributes).width
            if width > widest { widest = width }
        }
        return min(max(ceil(widest) + cellPadding, minimum), maximum)
    }
}
