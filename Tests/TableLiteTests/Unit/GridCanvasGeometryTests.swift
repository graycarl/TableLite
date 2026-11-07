import AppKit
import XCTest
@testable import TableLite

/// 网格画布的几何（`docs/tech-designs/07-data-grid.md` §4.1）。
///
/// 硬约束：
/// - 行带高度取「行高 + 行间距」，相邻两行首尾相接 —— 否则隔行色之间会露一条白缝。
/// - 只会算到有数据的行，空白区不出带、不出线。
/// - 列竖线按列宽累加算，跳过隐藏列，**最后一列可见列不画**（那里是表格外边）。
final class GridCanvasGeometryTests: XCTestCase {

    // MARK: 行区间

    func testRowRangeCoversVisibleRows() {
        let rows = NSRect(x: 0, y: 0, width: 800, height: 270) // 10 行 × 27pt
        let range = GridCanvasGeometry.rowRange(
            visible: NSRect(x: 0, y: 0, width: 800, height: 60),
            rowsRect: rows,
            step: 27,
            rowCount: 10
        )
        XCTAssertEqual(range, 0 ... 2)
    }

    /// 记录起点不在行边界时也要落在正确的行上（多算一行没关系，少算就会露白）。
    func testRowRangeHandlesMisalignedVisibleRect() {
        let range = GridCanvasGeometry.rowRange(
            visible: NSRect(x: 0, y: 13, width: 800, height: 40),
            rowsRect: NSRect(x: 0, y: 0, width: 800, height: 270),
            step: 27,
            rowCount: 10
        )
        XCTAssertEqual(range, 0 ... 1)
    }

    /// 可见区越过最后一行时夹在数据行内，空白区不画。
    func testRowRangeClampsToLastRow() {
        let range = GridCanvasGeometry.rowRange(
            visible: NSRect(x: 0, y: 200, width: 800, height: 400),
            rowsRect: NSRect(x: 0, y: 0, width: 800, height: 270),
            step: 27,
            rowCount: 10
        )
        XCTAssertEqual(range, 7 ... 9)
    }

    func testRowRangeIsNilWhenNothingToDraw() {
        let rows = NSRect(x: 0, y: 0, width: 800, height: 0)
        XCTAssertNil(GridCanvasGeometry.rowRange(visible: rows, rowsRect: rows, step: 27, rowCount: 0))
        XCTAssertNil(GridCanvasGeometry.rowRange(visible: rows, rowsRect: rows, step: 0, rowCount: 10))
        XCTAssertNil(
            GridCanvasGeometry.rowRange(
                visible: NSRect(x: 0, y: 0, width: 800, height: 10),
                rowsRect: rows,
                step: 27,
                rowCount: 0
            )
        )
    }

    // MARK: 行带

    /// 行带必须首尾相接：相邻两行之间不留缝（缝 = 露出网格底色的一条白线）。
    func testRowBandsAreContiguous() {
        let anchor = NSRect(x: 0, y: 0, width: 800, height: 26)
        let first = GridCanvasGeometry.rowBand(anchor: anchor, offset: 0, step: 27, width: 800, minX: 0)
        let second = GridCanvasGeometry.rowBand(anchor: anchor, offset: 1, step: 27, width: 800, minX: 0)

        XCTAssertEqual(first.height, 27)
        XCTAssertEqual(first.maxY, second.minY)
        XCTAssertEqual(second.minY, 27)
    }

    /// 隔行：奇数行铺（第二行起），与「第一行不铺」的视觉预期一致。
    func testStripedParity() {
        XCTAssertFalse(GridCanvasGeometry.isStriped(row: 0, parity: 1))
        XCTAssertTrue(GridCanvasGeometry.isStriped(row: 1, parity: 1))
        XCTAssertTrue(GridCanvasGeometry.isStriped(row: 2, parity: 0))
    }

    // MARK: 列竖线

    func testSeparatorsSitAtColumnRightEdges() {
        let xs = GridCanvasGeometry.columnSeparatorXs(
            columns: [(48, false), (100, false), (80, false)],
            intercellSpacing: 0
        )
        // 行号列右缘 48、第二列右缘 148；最后一列（80）不画。
        XCTAssertEqual(xs, [47, 147])
    }

    /// 隐藏列不占宽度、也不出线；「最后一列」按**可见**的最后一列算。
    func testSeparatorsSkipHiddenColumns() {
        let xs = GridCanvasGeometry.columnSeparatorXs(
            columns: [(48, false), (100, true), (80, false)],
            intercellSpacing: 0
        )
        XCTAssertEqual(xs, [47])
    }

    func testSeparatorsUseFullWidthOfLastVisibleColumn() {
        let xs = GridCanvasGeometry.columnSeparatorXs(
            columns: [(48, false), (100, false), (80, true)],
            intercellSpacing: 0
        )
        XCTAssertEqual(xs, [47])
    }

    /// 只有一列可见时不出线（那条会正好落在表格右边界上）。
    func testNoSeparatorForSingleVisibleColumn() {
        XCTAssertTrue(GridCanvasGeometry.columnSeparatorXs(columns: [(48, false)], intercellSpacing: 0).isEmpty)
        XCTAssertTrue(
            GridCanvasGeometry.columnSeparatorXs(
                columns: [(48, false), (100, true)],
                intercellSpacing: 0
            ).isEmpty
        )
        XCTAssertTrue(GridCanvasGeometry.columnSeparatorXs(columns: [], intercellSpacing: 0).isEmpty)
    }

    /// 列之间有间距时，竖线落在前一列自己的右缘上（不落进间距里）。
    func testSeparatorsAccountForIntercellSpacing() {
        let xs = GridCanvasGeometry.columnSeparatorXs(
            columns: [(48, false), (100, false)],
            intercellSpacing: 6
        )
        XCTAssertEqual(xs, [47])
    }
}
