import XCTest
@testable import TableLite

/// 单元格显示规则与二进制识别：`specs/03-data-browsing.md` §4、`07-data-grid.md` §4。
final class CellDisplayTests: XCTestCase {

    // MARK: 字节大小

    func testByteSizeFormatting() {
        XCTAssertEqual(ByteSize.format(0), "0 B")
        XCTAssertEqual(ByteSize.format(4), "4 B")
        XCTAssertEqual(ByteSize.format(1024), "1.0 KB")
        XCTAssertEqual(ByteSize.format(10_000), "9.8 KB")
        XCTAssertEqual(ByteSize.format(1_258_291), "1.2 MB")
    }

    // MARK: 二进制识别

    func testBinaryFormatDetection() {
        XCTAssertEqual(BinaryFormatDetector.detect(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])).displayName, "PNG")
        XCTAssertTrue(BinaryFormatDetector.detect(Data([0xFF, 0xD8, 0xFF, 0xE0])).isImage)
        XCTAssertTrue(BinaryFormatDetector.detect(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])).isImage)
        XCTAssertEqual(BinaryFormatDetector.detect(Data([0x25, 0x50, 0x44, 0x46, 0x2D])).displayName, "PDF")
        XCTAssertFalse(BinaryFormatDetector.detect(Data([0x00, 0x01, 0x02, 0x03])).isImage)
    }

    // MARK: 显示规则

    func testNullDisplay() {
        let column = TestSupport.column("name")
        let display = CellDisplayFormatter.display(value: .null, column: column)
        XCTAssertTrue(display.isNull)
        XCTAssertEqual(display.text, "NULL")
        XCTAssertEqual(display.alignment, .leading)
    }

    func testNullDisplayTextFollowsPreference() {
        let column = TestSupport.column("name")
        let context = CellDisplayContext(nullText: "(null)")
        let display = CellDisplayFormatter.display(value: .null, column: column, context: context)
        XCTAssertEqual(display.text, "(null)")
    }

    func testEmptyStringIsNotEmptyNull() {
        let column = TestSupport.column("name")
        let display = CellDisplayFormatter.display(value: .text(""), column: column)
        XCTAssertFalse(display.isNull)
        XCTAssertEqual(display.text, "")
    }

    func testNumericIsRightAligned() {
        let column = TestSupport.column("age", type: .long)
        let display = CellDisplayFormatter.display(value: .text("42"), column: column)
        XCTAssertEqual(display.alignment, .trailing)
    }

    func testDateIsRawText() {
        let column = TestSupport.column("created_at", type: .datetime, dataType: "datetime")
        let display = CellDisplayFormatter.display(value: .text("2025-01-01 10:00:00"), column: column)
        XCTAssertEqual(display.text, "2025-01-01 10:00:00")
        XCTAssertEqual(display.alignment, .leading)
    }

    func testTruncatedTextGetsEllipsisAndTooltip() {
        let column = TestSupport.column("content", type: .blob, dataType: "text")
        let display = CellDisplayFormatter.display(
            value: .text("这是一段被截断的文本"),
            isTruncated: true,
            totalByteCount: 10_000,
            column: column
        )
        XCTAssertEqual(display.text, "这是一段被截断的文本…")
        XCTAssertTrue(display.isTruncated)
        XCTAssertEqual(display.tooltip, "原始内容 9.8 KB，点开可查看完整内容")
    }

    func testShortBinaryShowsHex() {
        let column = TestSupport.column("token", type: .blob, charset: 63, dataType: "blob")
        let display = CellDisplayFormatter.display(value: .binary(Data([0xDE, 0xAD, 0xBE, 0xEF])), column: column)
        XCTAssertEqual(display.text, "0xDEADBEEF")
    }

    func testLargeBinaryShowsBlobPlaceholder() {
        let column = TestSupport.column("photo", type: .blob, charset: 63, dataType: "blob")
        let data = Data(repeating: 0x00, count: 12_595)
        let display = CellDisplayFormatter.display(value: .binary(data), column: column)
        XCTAssertEqual(display.text, "«BLOB 12.3 KB»")
    }

    func testImageBinaryShowsImagePlaceholder() {
        let column = TestSupport.column("photo", type: .blob, charset: 63, dataType: "blob")
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(Data(repeating: 0x00, count: 100))
        let display = CellDisplayFormatter.display(value: .binary(data), column: column)
        XCTAssertTrue(display.text.hasPrefix("«图片 PNG "))
        XCTAssertEqual(display.binaryFormat?.isImage, true)
    }

    func testGeometryPlaceholder() {
        let column = TestSupport.column("geo", type: .geometry, charset: 63, dataType: "geometry")
        let display = CellDisplayFormatter.display(value: .binary(Data(repeating: 0x01, count: 25)), column: column)
        XCTAssertEqual(display.text, "«GEOMETRY 25 B»")
    }

    func testTinyintBooleanCheckbox() {
        let column = TestSupport.column("flag", type: .tiny, length: 1, dataType: "tinyint", columnType: "tinyint(1)")
        let context = CellDisplayContext(tinyintAsCheckbox: true)
        XCTAssertEqual(CellDisplayFormatter.display(value: .text("1"), column: column, context: context).checkbox, .on)
        XCTAssertEqual(CellDisplayFormatter.display(value: .text("0"), column: column, context: context).checkbox, .off)
        XCTAssertEqual(CellDisplayFormatter.display(value: .null, column: column, context: context).checkbox, .mixed)
    }

    func testQuickLookKind() {
        let json = TestSupport.column("meta", type: .json, dataType: "json")
        XCTAssertEqual(CellDisplayFormatter.quickLookKind(for: json, value: .text("{}")), .json)
        let blob = TestSupport.column("data", type: .blob, charset: 63, dataType: "blob")
        XCTAssertEqual(CellDisplayFormatter.quickLookKind(for: blob, value: .binary(Data([0x00]))), .binary)
        let png = TestSupport.column("img", type: .blob, charset: 63, dataType: "blob")
        XCTAssertEqual(
            CellDisplayFormatter.quickLookKind(for: png, value: .binary(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))),
            .image
        )
    }

    // MARK: 十六进制 dump

    func testHexDump() {
        let dump = HexDump.format(Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertTrue(dump.hasPrefix("00000000"))
        XCTAssertTrue(dump.contains("89 50 4E 47"))
    }

    // MARK: 类型文案

    func testColumnTypeTextAndTooltip() {
        let column = TestSupport.column("content", type: .blob, dataType: "text", columnType: "longtext")
        XCTAssertEqual(column.typeDisplayText, "longtext")
        XCTAssertEqual(column.gridTypeTooltip, "`content` LONGTEXT NULL")
    }

    func testPrimaryKeyTypeTooltip() {
        let column = TestSupport.column(
            "id",
            type: .long,
            flags: ColumnFlag.primaryKey,
            dataType: "int",
            columnType: "int unsigned"
        )
        XCTAssertEqual(column.gridTypeTooltip, "`id` INT UNSIGNED NULL")
    }
}
