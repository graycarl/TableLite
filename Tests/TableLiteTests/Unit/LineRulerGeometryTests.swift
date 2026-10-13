import XCTest
@testable import TableLite

/// 行号栏分隔线的求交几何（`docs/tech-designs/10-query-editor.md` §2）。
final class LineRulerGeometryTests: XCTestCase {

    /// 正常情况：行号栏整高都在可视区内。
    func testSeparatorRectKeepsFullHeightWhenRulerFits() {
        let ruler = NSRect(x: 0, y: 0, width: 44, height: 200)
        let scroll = NSRect(x: 0, y: 0, width: 300, height: 200)

        let rect = LineRulerGeometry.separatorRect(rulerBounds: ruler, scrollBounds: scroll)

        XCTAssertFalse(rect.isNull)
        XCTAssertEqual(rect.height, 200, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 200, accuracy: 0.001)
        // 线贴在行号栏右缘：中心落在 maxX - 0.5（与旧绘制的位置一致）。
        XCTAssertEqual(rect.midX, 43.5, accuracy: 0.001)
    }

    /// 行号栏向上越界：上端被裁到可视区顶边。
    func testSeparatorRectClipsWhenRulerOverflowsTop() {
        let ruler = NSRect(x: 0, y: -80, width: 44, height: 280)
        let scroll = NSRect(x: 0, y: 0, width: 300, height: 200)

        let rect = LineRulerGeometry.separatorRect(rulerBounds: ruler, scrollBounds: scroll)

        XCTAssertFalse(rect.isNull)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 200, accuracy: 0.001)
        XCTAssertEqual(rect.height, 200, accuracy: 0.001)
    }

    /// 行号栏向下越界：下端被裁到可视区底边。
    func testSeparatorRectClipsWhenRulerOverflowsBottom() {
        let ruler = NSRect(x: 0, y: 0, width: 44, height: 320)
        let scroll = NSRect(x: 0, y: 0, width: 300, height: 200)

        let rect = LineRulerGeometry.separatorRect(rulerBounds: ruler, scrollBounds: scroll)

        XCTAssertFalse(rect.isNull)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 200, accuracy: 0.001)
        XCTAssertEqual(rect.height, 200, accuracy: 0.001)
    }

    /// 上下都越界：整段落在可视区内。
    func testSeparatorRectClipsBothEnds() {
        let ruler = NSRect(x: 0, y: -80, width: 44, height: 400)
        let scroll = NSRect(x: 0, y: 0, width: 300, height: 200)

        let rect = LineRulerGeometry.separatorRect(rulerBounds: ruler, scrollBounds: scroll)

        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 200, accuracy: 0.001)
    }

    /// 空交集：行号栏整体在可视区之下。
    func testSeparatorRectIsEmptyWhenNoOverlap() {
        let ruler = NSRect(x: 0, y: 300, width: 44, height: 100)
        let scroll = NSRect(x: 0, y: 0, width: 300, height: 200)

        let rect = LineRulerGeometry.separatorRect(rulerBounds: ruler, scrollBounds: scroll)

        XCTAssertTrue(rect.isNull || rect.height <= 0)
    }

    /// 空交集：可视区太窄，盖不到行号栏右缘的那条线。
    func testSeparatorRectIsEmptyWhenLineIsHorizontallyOutside() {
        let ruler = NSRect(x: 0, y: 0, width: 44, height: 200)
        let scroll = NSRect(x: 0, y: 0, width: 20, height: 200)

        let rect = LineRulerGeometry.separatorRect(rulerBounds: ruler, scrollBounds: scroll)

        XCTAssertTrue(rect.isNull || rect.width <= 0)
    }
}
