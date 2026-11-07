import AppKit
import XCTest
@testable import TableLite

/// 列宽自动适配（`specs/03-data-browsing.md` §5、`docs/tech-designs/07-data-grid.md` §4.2）。
///
/// 硬约束：
/// - 用真实字体量，不是「字符数 × 常数」：中文比 ASCII 宽得多。
/// - 60pt 下限、400pt 上限兜底。
/// - 单元格内边距留够，值不贴着竖线。
final class GridColumnWidthTests: XCTestCase {

    private let font = NSFont.systemFont(ofSize: 13)

    private func width(_ texts: [String]) -> CGFloat {
        GridColumnWidth.fit(texts: texts, font: font)
    }

    /// 只按列头量时至少顶到下限，不能量出细缝。
    func testShortHeaderHitsMinimum() {
        XCTAssertEqual(width(["id"]), GridColumnWidth.minimum)
        XCTAssertEqual(width([]), GridColumnWidth.minimum)
    }

    /// 取最长的那一条，而不是最后一条。
    func testWidestCandidateWins() {
        let long = "zhangsan.long@example.com"
        let narrow = width(["email"])
        let wide = width(["email", "a@b.c", long])
        XCTAssertGreaterThan(wide, narrow)
        // 宽出来的部分大致等于两段文本的宽度差。
        let expected = ("zhangsan.long@example.com" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(wide - GridColumnWidth.cellPadding, ceil(expected), accuracy: 1)
    }

    /// 长文本列不超过上限（400pt），否则一个字段能吃掉半屏。
    func testLongTextIsCapped() {
        let huge = String(repeating: "很长的一段内容", count: 200)
        XCTAssertEqual(width([huge]), GridColumnWidth.maximum)
    }

    /// 中文比等长的 ASCII 宽：旧的「字符数 × 8」就是在这里失效的。
    func testChineseIsWiderThanAsciiOfSameLength() {
        XCTAssertGreaterThan(width([String(repeating: "中", count: 20)]), width([String(repeating: "a", count: 20)]))
    }

    /// 尺寸随内容单调增长（截断前的最后一步也要更宽）。
    func testWidthGrowsWithContent() {
        let widths = [5, 10, 20, 30].map { width([String(repeating: "8", count: $0)]) }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(Set(widths).count, widths.count)
    }

    /// 恰好跨过下限的那一档：刚好不足 60 与刚好超过 60 要落在正确的一侧。
    func testBoundaryAroundMinimum() {
        // 12 个 "8" 约 73pt、加内边距 ≫ 60；"id" 只有 22pt 左右 → 夹到 60。
        XCTAssertEqual(width(["id"]), GridColumnWidth.minimum)
        XCTAssertGreaterThan(width([String(repeating: "8", count: 12)]), GridColumnWidth.minimum)
    }

    /// 空白字符串不当内容（否则一个纯空格的列会被量出空格宽度）。
    func testWhitespaceOnlyTextDoesNotDecideWidth() {
        XCTAssertEqual(width(["", "   "]), GridColumnWidth.minimum)
    }

    /// 上下限传反了也不崩：`min(max(…))` 先抬到下限再压回上限，最终落在上限。
    func testDegenerateBoundsClampToMaximum() {
        let width = GridColumnWidth.fit(
            texts: [String(repeating: "长", count: 40)],
            font: font,
            minimum: 300,
            maximum: 120
        )
        XCTAssertEqual(width, 120)
    }

    /// 内边距确实留了：量出来的宽度 > 纯文本宽度。
    func testCellPaddingIsIncluded() {
        let text = "created_at"
        let raw = (text as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(width([text]), ceil(raw) + GridColumnWidth.cellPadding)
    }
}
