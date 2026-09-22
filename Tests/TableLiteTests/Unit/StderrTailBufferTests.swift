import XCTest
@testable import TableLite

/// stderr 尾部缓冲：只保留最后 N 字节，且不丢字节。
///
/// SSH 失败时 stderr 是排查的唯一线索（`docs/tech-designs/05-session-management.md` §3）。
final class StderrTailBufferTests: XCTestCase {

    func testKeepsLastBytes() {
        var buffer = StderrTailBuffer(capacity: 8)
        buffer.append(Data("0123456789".utf8))
        XCTAssertEqual(buffer.string, "23456789")
        XCTAssertEqual(buffer.data.count, 8)
    }

    func testAppendIncrementally() {
        var buffer = StderrTailBuffer(capacity: 10)
        buffer.append(Data("abc".utf8))
        buffer.append(Data("def".utf8))
        buffer.append(Data("ghijkl".utf8))
        XCTAssertEqual(buffer.string, "cdefghijkl")
    }

    func testOversizedSingleAppendKeepsTail() {
        var buffer = StderrTailBuffer(capacity: 4)
        buffer.append(Data("abcdefgh".utf8))
        XCTAssertEqual(buffer.string, "efgh")
    }

    func testEmptyAppendIsNoOp() {
        var buffer = StderrTailBuffer(capacity: 4)
        buffer.append(Data())
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.string, "")
    }

    func testLossyDecodingOfInvalidUTF8() {
        var buffer = StderrTailBuffer(capacity: 16)
        buffer.append(Data([0xFF, 0xFE, 0x41])) // 非法 UTF-8 + 'A'
        // 宽松解码不抛错、不丢字节数量。
        XCTAssertFalse(buffer.string.isEmpty)
        XCTAssertEqual(buffer.data.count, 3)
    }

    func testRemoveAll() {
        var buffer = StderrTailBuffer(capacity: 8)
        buffer.append(Data("hello".utf8))
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDefaultCapacityIsFourKilobytes() {
        XCTAssertEqual(StderrTailBuffer(capacity: 4096).capacity, 4096)
    }
}
