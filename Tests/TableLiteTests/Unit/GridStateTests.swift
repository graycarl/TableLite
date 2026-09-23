import XCTest
@testable import TableLite

/// 显示条数 / 排序 / 行数估算 / Console Log 环形缓冲。
final class GridStateTests: XCTestCase {

    // MARK: 显示条数

    func testStatusTextShowsVisibleAndEstimatedRows() {
        let state = RowLimitState(limit: 300, rowCount: RowCountEstimate(approximate: 12480))
        XCTAssertEqual(state.statusText(visibleCount: 300), "显示 300 行 / 约 12,480 行")
        XCTAssertEqual(state.statusText(visibleCount: 0), "显示 0 行 / 约 12,480 行")
    }

    func testStatusTextWithoutEstimate() {
        XCTAssertEqual(RowLimitState(limit: 300).statusText(visibleCount: 5), "显示 5 行 / 行数未知")
    }

    func testInvalidLimitFallsBack() {
        XCTAssertEqual(RowLimitState(limit: 0).limit, RowLimit.default)
        XCTAssertEqual(RowLimitState(limit: 99999).limit, RowLimit.default)
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
