import XCTest
@testable import TableLite

/// 原始字节 + 列元数据 → `SQLValue` 的映射。
///
/// 见 `docs/tech-designs/03-mysql-layer.md` §4.1：数字 / 日期时间保留十进制原样文本，
/// 不做浮点转换、不做时区处理；二进制列走 `.binary`。
final class MySQLValueMappingTests: XCTestCase {

    func testNullStaysNull() {
        let column = TestSupport.column("name", type: .varString)
        XCTAssertEqual(MySQLValueMapping.value(for: .null, column: column), .null)
    }

    func testTextColumnStaysText() {
        let column = TestSupport.column("name", type: .varString)
        let value = MySQLValueMapping.value(for: .bytes(Data("hello 😀".utf8)), column: column)
        XCTAssertEqual(value, .text("hello 😀"))
    }

    func testNumericTextIsNotConverted() {
        let column = TestSupport.column("amount", type: .newdecimal)
        XCTAssertEqual(MySQLValueMapping.value(for: .bytes(Data("12.50".utf8)), column: column), .text("12.50"))
        XCTAssertEqual(MySQLValueMapping.value(for: .bytes(Data("1e5".utf8)), column: column), .text("1e5"))
    }

    func testBinaryColumnByCharsetNumber() {
        let column = TestSupport.column("payload", type: .blob, charset: 63)
        let data = Data([0x00, 0x1B, 0xFF])
        XCTAssertEqual(MySQLValueMapping.value(for: .bytes(data), column: column), .binary(data))
    }

    /// 协议层把数字列的 charset 也报成 63；不能因此把整数主键 hex 化。
    func testNumericColumnWithCharset63MapsToText() {
        let column = TestSupport.column("id", type: .long, charset: 63)
        XCTAssertEqual(MySQLValueMapping.value(for: .bytes(Data("7".utf8)), column: column), .text("7"))
    }

    /// 日期时间列同理：charset 63 不等于二进制。
    func testTemporalColumnWithCharset63MapsToText() {
        let column = TestSupport.column("created_at", type: .datetime, charset: 63)
        XCTAssertEqual(
            MySQLValueMapping.value(for: .bytes(Data("2025-01-01 12:00:00".utf8)), column: column),
            .text("2025-01-01 12:00:00")
        )
    }

    func testBinaryColumnByFlag() {
        let column = TestSupport.column("payload", type: .blob, flags: ColumnFlag.binary, charset: 33)
        XCTAssertTrue(column.isBinary)
        let data = Data([0x27, 0x5C])
        XCTAssertEqual(MySQLValueMapping.value(for: .bytes(data), column: column), .binary(data))
    }

    func testEmptyBytesAreDistinctFromNull() {
        let column = TestSupport.column("name", type: .varString)
        XCTAssertEqual(MySQLValueMapping.value(for: .bytes(Data()), column: column), .text(""))
        XCTAssertEqual(MySQLValueMapping.value(for: .null, column: column), .null)
    }

    func testRowMappingUsesColumnOrder() {
        let columns = [
            TestSupport.column("id", type: .long),
            TestSupport.column("name", type: .varString),
            TestSupport.column("blob", type: .blob, charset: 63),
        ]
        let row = MySQLRow(resultIndex: 0, rowIndex: 0, cells: [
            .bytes(Data("7".utf8)),
            .null,
            .bytes(Data([0xAB])),
        ])
        XCTAssertEqual(row.values(columns: columns), [.text("7"), .null, .binary(Data([0xAB]))])
    }

    func testRowMappingHandlesMissingColumnMetadata() {
        let row = MySQLRow(resultIndex: 0, rowIndex: 0, cells: [.bytes(Data("x".utf8)), .null])
        XCTAssertEqual(row.values(columns: []), [.text("x"), .null])
    }
}
