import AppKit

/// 网格的底纹与网格线（`docs/tech-designs/07-data-grid.md` §4.1）。
///
/// 一整块画一次，而不是让每行的 `NSTableRowView` 各画一遍：
/// 行视图里画，成本 = 可见行数 ×（隔行底色 + 1px 横线 + 每条竖线一条路径），
/// 200 列的表实测把滚动 p50 从 16.7ms 拖到 33ms；这里每帧只填几条横带 + 一条路径。
///
/// 摆放：`NSTableView` 的子视图，位于行视图**之下**（`positioned: .below`），
/// 帧高只覆盖数据行区域 —— 最后一行以下没有行，也就没有斑马纹和网格线
/// （`specs/03-data-browsing.md` §1）。
final class GridCanvasView: NSView {

    weak var ownerTableView: NSTableView?

    /// 隔行底色的颜色；`nil` 表示偏好关了交替行底色。
    var stripeColor: NSColor?
    /// 铺底色的行号奇偶：`row % 2 == stripeParity` 的行铺。
    var stripeParity = 1
    /// 列与列之间的竖线 x 坐标（表格内容坐标系），由协调者在列宽 / 列集合变化时算好。
    var columnSeparatorXs: [CGFloat] = []
    /// 数据行区域（表格内容坐标系）。
    var rowsRect: NSRect = .zero

    override var isFlipped: Bool { true }

    /// 纯底纹，不参与命中测试：点击照常落到行视图 / 单元格上。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let table = ownerTableView, rowsRect.height > 0 else { return }
        let visible = dirtyRect.intersection(rowsRect)
        guard !visible.isNull, visible.height > 0 else { return }

        let rows = visibleRows(in: visible, table: table)
        guard !rows.isEmpty else { return }
        drawStripes(rows)
        drawLines(rows, visible: visible)
    }

    /// 可见行的「行号 + 表格坐标系矩形」。行高统一，所以只向表格要一次起点，其余按步长推进。
    private func visibleRows(in visible: NSRect, table: NSTableView) -> [(row: Int, rect: NSRect)] {
        let step = table.rowHeight + table.intercellSpacing.height
        guard step > 0 else { return [] }
        let first = max(0, Int(((visible.minY - rowsRect.minY) / step).rounded(.down)))
        let last = min(table.numberOfRows - 1, Int(((visible.maxY - rowsRect.minY) / step).rounded(.up)))
        guard last >= first else { return [] }
        let anchor = table.rect(ofRow: first)
        return (first ... last).map { index in
            let y = anchor.minY + CGFloat(index - first) * step
            return (index, NSRect(x: visible.minX, y: y, width: visible.width, height: table.rowHeight))
        }
    }

    private func drawStripes(_ rows: [(row: Int, rect: NSRect)]) {
        guard let stripeColor else { return }
        let path = NSBezierPath()
        for (row, rect) in rows where row % 2 == stripeParity {
            path.appendRect(rect)
        }
        guard !path.isEmpty else { return }
        stripeColor.setFill()
        path.fill()
    }

    private func drawLines(_ rows: [(row: Int, rect: NSRect)], visible: NSRect) {
        // 横线：每行底部 1px，所有行合并成一条路径、一次填充。
        let horizontal = NSBezierPath()
        for (_, rect) in rows {
            horizontal.appendRect(NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
        }
        if !horizontal.isEmpty {
            AppNSColor.rowSeparator.setFill()
            horizontal.fill()
        }

        guard !columnSeparatorXs.isEmpty else { return }
        let vertical = NSBezierPath()
        for x in columnSeparatorXs where x + 1 > visible.minX && x < visible.maxX {
            vertical.appendRect(NSRect(x: x, y: visible.minY, width: 1, height: visible.height))
        }
        guard !vertical.isEmpty else { return }
        AppNSColor.cellSeparator.setFill()
        vertical.fill()
    }
}
