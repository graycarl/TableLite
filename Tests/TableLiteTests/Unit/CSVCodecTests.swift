import Foundation
import XCTest
@testable import TableLite

/// CSV 编解码边界。见 docs/tech-designs/11-schema-and-import-export.md §2。
final class CSVCodecTests: XCTestCase {

    // MARK: - 写

    func testEncodeFieldQuotesWhenContainsDelimiter() {
        XCTAssertEqual(CSVCodec.encodeField("a,b", delimiter: ","), "\"a,b\"")
    }

    func testEncodeFieldEscapesQuote() {
        XCTAssertEqual(CSVCodec.encodeField("a\"b", delimiter: ","), "\"a\"\"b\"")
    }

    func testEncodeFieldQuotesWhenContainsNewline() {
        XCTAssertEqual(CSVCodec.encodeField("a\nb", delimiter: ","), "\"a\nb\"")
        XCTAssertEqual(CSVCodec.encodeField("a\rb", delimiter: ","), "\"a\rb\"")
    }

    func testEncodeFieldQuotesWhenLeadingOrTrailingSpace() {
        XCTAssertEqual(CSVCodec.encodeField(" a", delimiter: ","), "\" a\"")
        XCTAssertEqual(CSVCodec.encodeField("a ", delimiter: ","), "\"a \"")
    }

    func testEncodeFieldPlainIsUnquoted() {
        XCTAssertEqual(CSVCodec.encodeField("abc", delimiter: ","), "abc")
        XCTAssertEqual(CSVCodec.encodeField("", delimiter: ","), "")
    }

    func testEncodeRowJoinsWithDelimiter() {
        XCTAssertEqual(CSVCodec.encodeRow(["a", "b,c", "d"], delimiter: ","), "a,\"b,c\",d")
        XCTAssertEqual(CSVCodec.encodeRow(["a", "b"], delimiter: "\t"), "a\tb")
    }

    // MARK: - exportText

    private func column(_ kind: ColumnKind) -> ResultSetColumn {
        ResultSetColumn(name: "c", originalTable: nil, originalColumn: nil, database: nil,
                        fieldType: 0, flags: 0, charsetNumber: 0, length: 0, decimals: 0,
                        kind: kind, isBinary: false, isNotNull: false, isPrimaryKey: false,
                        isUnsigned: false, isAutoIncrement: false)
    }

    func testExportTextNullStyles() {
        XCTAssertEqual(CSVCodec.exportText(.null, column: nil, nullStyle: .empty), "")
        XCTAssertEqual(CSVCodec.exportText(.null, column: nil, nullStyle: .literalNULL), "NULL")
    }

    func testExportTextBinaryBecomesUppercaseHex() {
        let value = CellValue.bytes([0x00, 0xAB, 0xFF])
        XCTAssertEqual(CSVCodec.exportText(value, column: column(.blob), nullStyle: .empty), "0x00ABFF")
    }

    func testExportTextInvalidUTF8BecomesHex() {
        let value = CellValue.bytes([0xFF, 0xFE])
        XCTAssertEqual(CSVCodec.exportText(value, column: nil, nullStyle: .empty), "0xFFFE")
    }

    /// 合法 UTF-8 但属于二进制列时也必须 hex（docs/11 §2.1）。
    func testExportTextExplicitBinaryFlagBeatsValidUTF8() {
        let value = CellValue.bytes([0x41, 0x42, 0x00])
        XCTAssertEqual(CSVCodec.exportText(value, isBinary: true, nullStyle: .empty), "0x414200")
        XCTAssertEqual(CSVCodec.exportText(value, isBinary: false, nullStyle: .empty), "AB\0")
    }

    func testExportTextKeepsServerFloatText() {
        let value = CellValue.text("3.1400000000000001")
        XCTAssertEqual(CSVCodec.exportText(value, column: column(.floating), nullStyle: .empty),
                       "3.1400000000000001")
    }

    func testExportTextPlainString() {
        XCTAssertEqual(CSVCodec.exportText(.text("张三"), column: column(.text), nullStyle: .empty), "张三")
    }

    func testByteOrderMark() {
        XCTAssertEqual(CSVCodec.byteOrderMark(for: .utf8), [])
        XCTAssertEqual(CSVCodec.byteOrderMark(for: .utf8BOM), [0xEF, 0xBB, 0xBF])
    }

    // MARK: - 读：基本

    private func parse(_ text: String, delimiter: Character? = ",") throws -> [[String]] {
        try CSVCodec.parse(Data(text.utf8), delimiter: delimiter).rows
    }

    func testParseBasicRows() throws {
        XCTAssertEqual(try parse("a,b\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testParseQuotedDelimiterAndNewline() throws {
        let text = "\"a,b\",\"c\nd\"\n"
        XCTAssertEqual(try parse(text), [["a,b", "c\nd"]])
    }

    func testParseEscapedQuotes() throws {
        XCTAssertEqual(try parse("\"a\"\"b\",c"), [["a\"b", "c"]])
    }

    func testParsePreservesLeadingAndTrailingSpaces() throws {
        XCTAssertEqual(try parse("a , b"), [["a ", " b"]])
    }

    func testParseLastLineWithoutNewline() throws {
        XCTAssertEqual(try parse("a,b\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testParseTrailingNewlineDoesNotAddEmptyRow() throws {
        XCTAssertEqual(try parse("a,b\n"), [["a", "b"]])
    }

    func testParsePadsShortRows() throws {
        XCTAssertEqual(try parse("a,b,c\n1,2"), [["a", "b", "c"], ["1", "2", ""]])
    }

    func testParseCRLF() throws {
        XCTAssertEqual(try parse("a,b\r\nc,d"), [["a", "b"], ["c", "d"]])
    }

    func testParseCR() throws {
        XCTAssertEqual(try parse("a,b\rc,d"), [["a", "b"], ["c", "d"]])
    }

    func testParseStripsUTF8BOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Array("a,b".utf8))
        XCTAssertEqual(try CSVCodec.parse(data, delimiter: ",").rows, [["a", "b"]])
    }

    // MARK: - 读：错误

    func testParseEmptyFileThrows() {
        XCTAssertThrowsError(try CSVCodec.parse(Data(), delimiter: ",")) { error in
            XCTAssertEqual(error as? CSVCodec.ParseError, .emptyFile)
        }
    }

    func testParseUnclosedQuoteThrowsWithRow() {
        XCTAssertThrowsError(try CSVCodec.parse(Data("a,\"bc".utf8), delimiter: ",")) { error in
            XCTAssertEqual(error as? CSVCodec.ParseError, .unclosedQuote(row: 1))
        }
    }

    func testParseUnclosedQuoteRowNumber() {
        XCTAssertThrowsError(try CSVCodec.parse(Data("a,b\nc,\"d".utf8), delimiter: ",")) { error in
            XCTAssertEqual(error as? CSVCodec.ParseError, .unclosedQuote(row: 2))
        }
    }

    func testParseInconsistentColumnsThrowsWithRow() {
        XCTAssertThrowsError(try CSVCodec.parse(Data("a,b\n1,2,3".utf8), delimiter: ",")) { error in
            XCTAssertEqual(error as? CSVCodec.ParseError,
                           .inconsistentColumns(row: 2, expected: 2, actual: 3))
        }
    }

    // MARK: - 编码检测

    func testDetectEncodingUTF8() {
        XCTAssertEqual(CSVCodec.detectEncoding(Data("中文".utf8)), "UTF-8")
    }

    func testDetectEncodingGB18030() {
        // "中文" 的 GB18030 字节
        XCTAssertEqual(CSVCodec.detectEncoding(Data([0xD6, 0xD0, 0xCE, 0xC4])), "GB18030")
    }

    func testDetectEncodingUTF16BOM() {
        let data = Data([0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00])
        XCTAssertEqual(CSVCodec.detectEncoding(data), "UTF-16")
    }

    func testDetectEncodingUndecodable() {
        // 不完整 / 非法的多字节序列：UTF-8、GB18030 均失败且无 UTF-16 BOM
        XCTAssertNil(CSVCodec.detectEncoding(Data([0x81, 0x30, 0x81])))
    }

    func testParseUndecodableThrows() {
        XCTAssertThrowsError(try CSVCodec.parse(Data([0x81, 0x30, 0x81]), delimiter: ",")) { error in
            XCTAssertEqual(error as? CSVCodec.ParseError, .undecodableText)
        }
    }

    func testParseGB18030() throws {
        // "中,文" 的 GB18030 字节
        let data = Data([0xD6, 0xD0, 0x2C, 0xCE, 0xC4])
        let result = try CSVCodec.parse(data, delimiter: ",")
        XCTAssertEqual(result.detectedEncoding, "GB18030")
        XCTAssertEqual(result.rows, [["中", "文"]])
    }

    // MARK: - 分隔符检测

    func testDetectDelimiterComma() {
        XCTAssertEqual(CSVCodec.detectDelimiter("a,b,c\n1,2,3"), ",")
    }

    func testDetectDelimiterTab() {
        XCTAssertEqual(CSVCodec.detectDelimiter("a\tb\tc\n1\t2\t3"), "\t")
    }

    func testDetectDelimiterSemicolon() {
        XCTAssertEqual(CSVCodec.detectDelimiter("a;b;c\n1;2;3"), ";")
    }

    func testDetectDelimiterPipe() {
        XCTAssertEqual(CSVCodec.detectDelimiter("a|b|c\n1|2|3"), "|")
    }

    func testDetectDelimiterFallsBackToComma() {
        XCTAssertEqual(CSVCodec.detectDelimiter("abc\ndef"), ",")
    }

    func testParseAutoDetectsDelimiter() throws {
        let result = try CSVCodec.parse(Data("a;b\n1;2".utf8), delimiter: nil)
        XCTAssertEqual(result.detectedDelimiter, ";")
        XCTAssertEqual(result.rows, [["a", "b"], ["1", "2"]])
    }
}

// MARK: - Stream 导出（docs/11 §3.1）

final class CSVExporterTests: XCTestCase {

    private func makeFileSystem() -> InMemoryFileSystemLocator {
        InMemoryFileSystemLocator()
    }

    private func simpleStream(_ rows: [[CellValue]]) -> AsyncThrowingStream<[CellValue], Error> {
        AsyncThrowingStream { continuation in
            for row in rows { continuation.yield(row) }
            continuation.finish()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    func testWriteProducesHeaderAndRows() async throws {
        let fileSystem = makeFileSystem()
        let destination = fileSystem.root.appendingPathComponent("Out/result.csv")
        let exporter = CSVExporter(fileSystem: fileSystem, options: CSVCodec.Options())

        let rows: [[CellValue]] = [[.text("1"), .null], [.text("x"), .text("y")]]
        try await exporter.write(to: destination,
                                 header: ["a", "b"],
                                 rows: simpleStream(rows),
                                 onProgress: { _, _ in },
                                 cancellation: { false })

        let data = try fileSystem.readData(at: destination)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "a,b\n1,\nx,y\n")
    }

    func testWriteWithBOM() async throws {
        let fileSystem = makeFileSystem()
        let destination = fileSystem.root.appendingPathComponent("Out/bom.csv")
        let exporter = CSVExporter(fileSystem: fileSystem,
                                   options: CSVCodec.Options(encoding: .utf8BOM))

        try await exporter.write(to: destination,
                                 header: ["a"],
                                 rows: simpleStream([[.text("1")]]),
                                 onProgress: { _, _ in },
                                 cancellation: { false })

        let data = try fileSystem.readData(at: destination)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    /// 带二进制标记的列必须 hex 输出，即使字节恰好是合法 UTF-8。
    func testWriteHexEncodesFlaggedBinaryColumn() async throws {
        let fileSystem = makeFileSystem()
        let destination = fileSystem.root.appendingPathComponent("Out/bin.csv")
        let exporter = CSVExporter(fileSystem: fileSystem, options: CSVCodec.Options())

        try await exporter.write(to: destination,
                                 header: ["payload"],
                                 rows: simpleStream([[.bytes([0x41, 0x42, 0x00])]]),
                                 onProgress: { _, _ in },
                                 cancellation: { false },
                                 binaryColumnFlags: [true])

        let data = try fileSystem.readData(at: destination)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "payload\n0x414200\n")
    }

    func testCancellationLeavesPartialFile() async throws {
        let fileSystem = makeFileSystem()
        let destination = fileSystem.root.appendingPathComponent("Out/cancel.csv")
        let exporter = CSVExporter(fileSystem: fileSystem, options: CSVCodec.Options())
        let counter = Counter()

        let rows: [[CellValue]] = (0..<10).map { [.text("\($0)")] }
        do {
            try await exporter.write(to: destination,
                                     header: ["n"],
                                     rows: simpleStream(rows),
                                     onProgress: { _, _ in },
                                     cancellation: { counter.increment() > 2 })
            XCTFail("应当抛出 incomplete")
        } catch let error as CSVExportError {
            guard case .incomplete(let partialURL) = error else {
                return XCTFail("期望 incomplete，实际 \(error)")
            }
            XCTAssertTrue(fileSystem.fileExists(at: partialURL))
            XCTAssertFalse(fileSystem.fileExists(at: destination), "正式文件不应存在")
            let text = String(decoding: try fileSystem.readData(at: partialURL), as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("n\n0\n1\n"), "已写内容应保留，实际：\(text)")
        }
    }

    func testStreamErrorLeavesPartialFile() async throws {
        let fileSystem = makeFileSystem()
        let destination = fileSystem.root.appendingPathComponent("Out/error.csv")
        let exporter = CSVExporter(fileSystem: fileSystem, options: CSVCodec.Options())

        let stream = AsyncThrowingStream<[CellValue], Error> { continuation in
            continuation.yield([.text("1")])
            continuation.finish(throwing: MySQLError.connectionLost(nil))
        }
        do {
            try await exporter.write(to: destination,
                                     header: ["n"],
                                     rows: stream,
                                     onProgress: { _, _ in },
                                     cancellation: { false })
            XCTFail("应当抛出 incomplete")
        } catch let error as CSVExportError {
            guard case .incomplete(let partialURL) = error else {
                return XCTFail("期望 incomplete，实际 \(error)")
            }
            XCTAssertTrue(fileSystem.fileExists(at: partialURL))
        }
    }
}
