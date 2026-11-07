import AppKit

/// 字段栏多行编辑器的高度计算（`specs/03-data-browsing.md` §7、`docs/tech-designs/14-row-inspector.md` §9）。
///
/// 纯逻辑。`NSTextView` 自己不报高度：给它 `minHeight` 就只有那么高（长文本被压成一行 +
/// 滚动条），用 `NSViewRepresentable.sizeThatFits` 又会让 `NSScrollView` 和 SwiftUI 的行高打架。
/// 所以高度在 SwiftUI 侧按「文本 + 可用宽度」量出来。
enum InspectorFieldHeight {

    struct Fit: Equatable {
        /// 编辑器该有的高度（含上下文本内边距）。
        let height: CGFloat
        /// 内容超过行数上限，界面该给「展开」入口。
        let isTruncated: Bool
    }

    /// 采样上限：600 个字符在任何允许的栏宽（260–560pt）下都已经远超 3 行，
    /// 再长的文本不必整篇排版 —— 字段栏的大字段可能有几 MB，全量 `boundingRect` 要 1 秒以上。
    static let sampleLength = 600

    /// - Parameters:
    ///   - width: 编辑器实际可用的文本宽度。
    ///   - lineLimit: 展开前的最大行数。
    ///   - verticalInset: 文本容器上下内边距（两边各一份）。
    static func fit(
        text: String,
        width: CGFloat,
        font: NSFont,
        lineLimit: Int,
        verticalInset: CGFloat
    ) -> Fit {
        let limit = max(lineLimit, 1)
        let lineHeight = lineHeight(for: font)
        let cappedHeight = lineHeight * CGFloat(limit)
        let insetHeight = verticalInset * 2

        // 超长文本直接按「已截断」处理，避免一次排版几 MB（AGENTS 坑 §6：热路径不碰派生属性）。
        guard text.count <= sampleLength else {
            return Fit(height: cappedHeight + insetHeight, isTruncated: true)
        }

        let sample = (text.isEmpty ? " " : text) as NSString
        let bounding = sample.boundingRect(
            with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height

        // 按整行截断：留半行会露出一条被裁掉的字形碎片。
        let used = min(bounding, cappedHeight)
        return Fit(height: used + insetHeight, isTruncated: bounding > cappedHeight + 0.5)
    }

    /// 单行高度（含行距），按整数像素向上取整，免得累积误差切掉字形底部。
    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
