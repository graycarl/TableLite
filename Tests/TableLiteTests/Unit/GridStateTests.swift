import XCTest
@testable import TableLite

/// 分页 / 排序 / 行数估算 / Console Log 环形缓冲。
final class GridStateTests: XCTestCase {

    // MARK: 分页

    func testOffsetAndVisibleRowCount() {
        let page = PageState(pageIndex: 2, pageSize: 300)
        XCTAssertEqual(page.offset, 600)
        XCTAssertEqual(page.visibleRowCount(fetchedRowCount: 301), 300)
        XCTAssertEqual(page.visibleRowCount(fetchedRowCount: 120), 120)
    }

    func testHasNextPage() {
        let page = PageState(pageIndex: 0, pageSize: 300)
        XCTAssertTrue(page.hasNextPage(fetchedRowCount: 301))
        XCTAssertFalse(page.hasNextPage(fetchedRowCount: 300))
    }

    func testPageStatusText() {
        let page = PageState(pageIndex: 0, pageSize: 300, rowCount: RowCountEstimate(approximate: 12480))
        XCTAssertEqual(page.statusText(visibleCount: 300), "行 1–300 / 约 12,480 行 · 第 1 页 · 300 行/页")
    }

    func testPageCount() {
        let page = PageState(pageIndex: 0, pageSize: 300, rowCount: RowCountEstimate(approximate: 12480))
        XCTAssertEqual(page.pageCount, 42)
        let unreliable = PageState(rowCount: RowCountEstimate(approximate: 0, isReliable: false))
        XCTAssertNil(unreliable.pageCount)
    }

    func testInvalidPageSizeFallsBack() {
        XCTAssertEqual(PageState(pageSize: 0).pageSize, PageSize.default)
        XCTAssertEqual(PageState(pageSize: 99999).pageSize, PageSize.default)
    }

    func testNavigation() {
        var page = PageState(pageIndex: 1)
        page.goToNextPage()
        XCTAssertEqual(page.pageIndex, 2)
        page.goToPreviousPage()
        page.goToPreviousPage()
        page.goToPreviousPage()
        XCTAssertEqual(page.pageIndex, 0)
        page.resetToFirstPage()
        XCTAssertEqual(page.pageIndex, 0)
    }

    func testDeepOffsetFlag() {
        XCTAssertFalse(PageState(pageIndex: 100, pageSize: 300).isDeepOffset) // offset 30000
        XCTAssertTrue(PageState(pageIndex: 400, pageSize: 300).isDeepOffset) // offset 120000
    }

    // MARK: 行数估算

    func testRowCountEstimateDisplay() {
        XCTAssertEqual(RowCountEstimate(approximate: 12480).displayText, "约 12,480 行")
        XCTAssertEqual(RowCountEstimate(approximate: 12480, isExact: true).displayText, "12,480 行")
        XCTAssertEqual(RowCountEstimate(approximate: 0, isReliable: false).displayText, "约 0 行（估算不可靠）")
    }

    func testLeadingZeroAndNegativeGrouping() {
        let estimate = RowCountEstimate(approximate: 1_000_000)
        XCTAssertEqual(estimate.displayText, "约 1,000,000 行")
        XCTAssertEqual(RowCountEstimate(approximate: -5_000).displayText, "约 -5,000 行")
        XCTAssertEqual(RowCountEstimate(approximate: 7).displayText, "约 7 行")
    }

    // MARK: 排序

    func testSortDirectionCycle() {
        XCTAssertEqual(SortDirection.ascending.next, .descending)
        XCTAssertNil(SortDirection.descending.next)
        XCTAssertEqual(SortDirection.ascending.arrow, "▲")
        XCTAssertEqual(SortDirection.descending.keyword, "DESC")
    }

    // MARK: 环形缓冲

    func testRingBufferDropsOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.elements, [3, 4, 5])
    }

    func testRingBufferRemoveAll() {
        var buffer = RingBuffer<Int>(capacity: 2)
        buffer.append(1)
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.capacity, 2)
    }

    func testConsoleLogEntrySuccess() {
        let success = ConsoleLogEntry(id: 1, timestamp: Date(timeIntervalSince1970: 0), tag: .data, sql: "SELECT 1")
        let failure = ConsoleLogEntry(id: 2, timestamp: Date(timeIntervalSince1970: 0), tag: .meta, sql: "SELECT 2", errorCode: 1064)
        XCTAssertTrue(success.isSuccess)
        XCTAssertFalse(failure.isSuccess)
    }
}
