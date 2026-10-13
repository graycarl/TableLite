import Foundation

/// 行号栏分隔线的几何计算（`docs/tech-designs/10-query-editor.md` §2）。
///
/// 纯函数：给定行号栏 `NSRulerView` 的 `bounds` 与编辑器可视区，算出那条 1px 竖线
/// 应该画在哪里。越界部分先与可视区求交再画，不依赖任何视图状态，便于单测。
enum LineRulerGeometry {

    /// 分隔线的绘制矩形。
    ///
    /// 线贴在 `rulerBounds` 的右缘（`separatorColor` 的 1px 竖线），纵向范围是
    /// `rulerBounds` 的整高，最后与 `scrollBounds`（编辑器可视区）求交：
    ///
    /// - `rulerBounds` 向上越界（`rulerBounds.minY < scrollBounds.minY`）→ 上端被裁掉；
    /// - 向下越界（`rulerBounds.maxY > scrollBounds.maxY`）→ 下端被裁掉；
    /// - 完全不重叠 → 返回空矩形（`NSRect.null` / `isEmpty`），调用方不画。
    static func separatorRect(rulerBounds: NSRect, scrollBounds: NSRect) -> NSRect {
        let line = NSRect(
            x: rulerBounds.maxX - 1,
            y: rulerBounds.minY,
            width: 1,
            height: rulerBounds.height
        )
        return line.intersection(scrollBounds)
    }
}
