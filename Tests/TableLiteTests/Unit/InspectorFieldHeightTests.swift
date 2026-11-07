import AppKit
import XCTest
@testable import TableLite

/// 字段栏多行编辑器的高度计算（`specs/03-data-browsing.md` §7、`docs/tech-designs/14-row-inspector.md` §9）。
///
/// 硬约束：
/// - 空值 / 一行内容只占一行高（不能像以前那样写死两行半）。
/// - 超过上限就截断并给出「展开」入口，高度不超过上限。
/// - 超长文本不整篇排版（大字段可能几 MB，热路径不能卡）。
final class InspectorFieldHeightTests: XCTestCase {

    private let font = NSFont.systemFont(ofSize: 13)
    private let inset: CGFloat = 4
    private let limit = 3

    private func fit(_ text: String, width: CGFloat = 276) -> InspectorFieldHeight.Fit {
        InspectorFieldHeight.fit(
            text: text,
            width: width,
            font: font,
            lineLimit: limit,
            verticalInset: inset
        )
    }

    /// 一行高 = 单行行高 + 上下内边距，空文本也不能更矮。
    func testEmptyTextTakesExactlyOneLine() {
        let oneLine = InspectorFieldHeight.lineHeight(for: font) + inset * 2
        let result = fit("")

        XCTAssertEqual(result.height, oneLine, accuracy: 0.5)
        XCTAssertFalse(result.isTruncated)
    }

    func testSingleShortLineIsNotTruncated() {
        XCTAssertFalse(fit("zhang@example.com").isTruncated)
    }

    /// 上限之上的文本必须报截断，高度停在「上限行数」上（按整行截断，不留半行碎片）。
    func testOverflowIsCappedToLineLimit() {
        let result = fit(String(repeating: "很长的一段文本。", count: 60))
        let cap = InspectorFieldHeight.lineHeight(for: font) * CGFloat(limit) + inset * 2

        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.height, cap, accuracy: 0.5)
    }

    /// 换行符本身也占行：三行内容刚好到上限，不该被算成截断。
    func testNewlinesCountAsLines() {
        XCTAssertFalse(fit("一\n二\n三").isTruncated)
        XCTAssertTrue(fit("一\n二\n三\n四").isTruncated)
    }

    /// 超长文本走采样短路：不排版全文，直接判为截断并给上限高度。
    func testVeryLongTextSkipsFullLayout() {
        let long = String(repeating: "x", count: InspectorFieldHeight.sampleLength + 1)
        let result = fit(long, width: 100)
        let cap = InspectorFieldHeight.lineHeight(for: font) * CGFloat(limit) + inset * 2

        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.height, cap, accuracy: 0.5)
    }

    /// 窄栏比宽栏更容易提前截断。
    func testNarrowerWidthOverflowsSooner() {
        let text = String(repeating: "自动换行的一段话。", count: 12)

        XCTAssertFalse(fit(text, width: 560).isTruncated)
        XCTAssertTrue(fit(text, width: 200).isTruncated)
    }

    /// 高度永远落在 [一行, 上限] 之间，宽度给 0 也不崩。
    func testHeightStaysWithinBoundsForDegenerateWidth() {
        let oneLine = InspectorFieldHeight.lineHeight(for: font) + inset * 2
        let cap = InspectorFieldHeight.lineHeight(for: font) * CGFloat(limit) + inset * 2

        for width in [CGFloat(0), 1, 80, 276, 560] {
            let height = fit(String(repeating: "内容", count: 200), width: width).height
            XCTAssertGreaterThanOrEqual(height, oneLine)
            XCTAssertLessThanOrEqual(height, cap + 0.5)
        }
    }
}
