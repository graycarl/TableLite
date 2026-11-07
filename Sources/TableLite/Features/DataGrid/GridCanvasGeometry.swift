import AppKit

/// 网格画布的几何计算（`docs/tech-designs/07-data-grid.md` §4.1）。
///
/// 纯逻辑、可单测：行的 y 区间、隔行判定、列竖线的 x。放在这里而不是散在视图里，
/// 是因为这几处最容易差 1pt —— 行带盖不住 `intercellSpacing` 就会在两条隔行色之间
/// 留一条白缝，列竖线错一列就会画到表格外边。
enum GridCanvasGeometry {

    /// 可见行区间（含两端）。`visible` 已经与行区域求过交。
    static func rowRange(
        visible: NSRect,
        rowsRect: NSRect,
        step: CGFloat,
        rowCount: Int
    ) -> ClosedRange<Int>? {
        guard step > 0, rowCount > 0, !visible.isNull, visible.height > 0 else { return nil }
        let first = max(0, Int(((visible.minY - rowsRect.minY) / step).rounded(.down)))
        // 末行按「上沿落在哪一行」算：可见区下边界正好压在行边界上时，不多算一行。
        let last = min(rowCount - 1, Int(((visible.maxY - rowsRect.minY) / step).rounded(.up)) - 1)
        guard last >= first else { return nil }
        return first ... last
    }

    /// 行带矩形：高度取 `step`（行高 + 行间距），这样相邻两行首尾相接 ——
    /// 只取 `rowHeight` 会露出 `intercellSpacing` 的底色，隔行色之间出现一条白缝。
    static func rowBand(anchor: NSRect, offset: Int, step: CGFloat, width: CGFloat, minX: CGFloat) -> NSRect {
        NSRect(
            x: minX,
            y: anchor.minY + CGFloat(offset) * step,
            width: width,
            height: step
        )
    }

    /// 隔行底色的行号：`row % 2 == parity`。
    static func isStriped(row: Int, parity: Int) -> Bool {
        row % 2 == parity
    }

    /// 列竖线的 x 坐标：累加列宽算出每列的右缘，跳过隐藏列，最后一列可见列不画
    /// （那里是表格外边）。
    ///
    /// 按宽度累加而不是问 `rect(ofColumn:)`：首帧还没参与布局时后者不可信，
    /// 而且 200 列的表上每次重算要跑 200 次几何查询。
    static func columnSeparatorXs(
        columns: [(width: CGFloat, isHidden: Bool)],
        intercellSpacing: CGFloat
    ) -> [CGFloat] {
        let visible = columns.enumerated().filter { !$0.element.isHidden }
        guard visible.count > 1 else { return [] }
        var xs: [CGFloat] = []
        xs.reserveCapacity(visible.count - 1)
        var x: CGFloat = 0
        for (offset, column) in visible.enumerated() {
            x += column.element.width + intercellSpacing
            guard offset < visible.count - 1 else { break }
            xs.append((x - intercellSpacing - 1).rounded(.down))
        }
        return xs
    }
}
