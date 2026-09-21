import XCTest
@testable import TableLite

/// 导出 / 导入 CSV 真库往返测试：导出整表 → 建同构新表 → `CSVImporter` 导入 → 数据一致。
///
/// 覆盖 NULL / 引号 / 换行 / emoji；另单独验证二进制列导出为 `0x…` hex。
/// 见 docs/tech-designs/11-schema-and-import-export.md §2 §3 §4。
final class CSVRoundTripIntegrationTests: MySQLIntegrationTestCase {

    override class var databaseName: String { "tablelite_it_csv" }

    private var root: URL!
    private var fileSystem: InMemoryFileSystemLocator!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteCSVTests-\(UUID().uuidString)", isDirectory: true)
        fileSystem = InMemoryFileSystemLocator(root: root)
    }

    override func tearDown() async throws {
        // setUp 在建库前跳过时 root 仍为 nil，不能直接强解包
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    private func ref(_ table: String) -> TableRef {
        TableRef(database: Self.databaseName, table: table)
    }

    /// 用真实 `CSVExporter` 把整表导出到临时文件，返回文件内容。
    private func exportCSV(table: String, options: CSVCodec.Options = CSVCodec.Options()) async throws -> Data {
        let structure = try await tableStructure(table)
        let literalizer = await session.literalizer()
        let sql = try TableDataQueryBuilder.exportSQL(ref: ref(table),
                                                      structure: structure,
                                                      filter: FilterSet(),
                                                      sort: [],
                                                      literalizer: literalizer)
        let resultSet = try await firstResultSet(sql)
        let rows = resultSet?.rows ?? []
        let header = resultSet?.header.columns.map(\.name) ?? []

        let stream = AsyncThrowingStream<[CellValue], Error> { continuation in
            for row in rows { continuation.yield(row) }
            continuation.finish()
        }
        let destination = fileSystem.temporaryDirectory.appendingPathComponent("\(table).csv")
        try await CSVExporter(fileSystem: fileSystem, options: options).write(
            to: destination,
            header: header,
            rows: stream,
            onProgress: { _, _ in },
            cancellation: { false },
            binaryColumnFlags: structure.columns.map { $0.kind.isBinaryLike || $0.isBinary }
        )
        return try fileSystem.readData(at: destination)
    }

    private func importCSV(_ data: Data, intoTable table: String) async throws -> [String] {
        let parsed = try CSVCodec.parse(data, delimiter: nil)
        let structure = try await tableStructure(table)
        let csvHeader = parsed.rows[0]
        let mapping = csvHeader.enumerated().compactMap { index, name -> CSVImporter.ColumnMapping? in
            guard structure.columns.contains(where: { $0.name == name }) else { return nil }
            return CSVImporter.ColumnMapping(sourceIndex: index, targetColumn: name)
        }
        let literalizer = await session.literalizer()
        let statements = CSVImporter.insertBatches(table: ref(table),
                                                   targetColumns: structure.columns,
                                                   mapping: mapping,
                                                   rows: Array(parsed.rows.dropFirst()),
                                                   literalizer: literalizer,
                                                   batchSize: 500)
        for statement in statements {
            try await session.execute(statement)
        }
        return statements
    }

    /// 往返：同构 `t_src` → 导出 → 导入 `t_dst` → 逐行比较。
    func testRoundTripIntoNewTable() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_src")) (
              id INT PRIMARY KEY,
              name VARCHAR(128),
              note TEXT
            )
            """)
        let literalizer = await session.literalizer()
        func text(_ value: String) -> String {
            SQLValueLiteral.literal(.text(value), kind: .text, using: literalizer)
        }
        let tuples = [
            "(1, \(text("O'Reilly")), \(text("含逗号,和\"引号\"")))",
            "(2, \(text("第一行\n第二行\t带制表")), NULL)",
            "(3, \(text("emoji 😀🌊")), \(text("plain")))",
        ]
        try await session.execute("INSERT INTO \(qualified("t_src")) (id, name, note) VALUES "
            + tuples.joined(separator: ","))

        let data = try await exportCSV(table: "t_src")

        try await session.execute("""
            CREATE TABLE \(qualified("t_dst")) (
              id INT PRIMARY KEY,
              name VARCHAR(128),
              note TEXT
            )
            """)
        let statements = try await importCSV(data, intoTable: "t_dst")
        XCTAssertFalse(statements.isEmpty)

        let original = try await firstResultSet("""
            SELECT id, name, IFNULL(note, '<NULL>') FROM \(qualified("t_src")) ORDER BY id
            """)
        let imported = try await firstResultSet("""
            SELECT id, name, IFNULL(note, '<NULL>') FROM \(qualified("t_dst")) ORDER BY id
            """)
        XCTAssertEqual(imported?.rows.map { $0.map(\.displayText) },
                       original?.rows.map { $0.map(\.displayText) })

        // NULL 必须保持 NULL，而不是空字符串
        let nullCount = try await firstResultSet("""
            SELECT COUNT(*) FROM \(qualified("t_dst")) WHERE note IS NULL
            """)
        XCTAssertEqual(nullCount?.rows.first?.first?.displayText, "1")
    }

    /// 二进制列即使字节恰好是合法 UTF-8 也必须导出为 hex（docs/11 §2.1）。
    func testBinaryColumnExportsAsHexEvenWhenBytesAreValidUTF8() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_bin")) (id INT PRIMARY KEY, payload VARBINARY(32))
            """)
        let validUTF8: [UInt8] = [0x41, 0x42, 0x00] // "AB\0" —— 合法 UTF-8，但属于二进制列
        let invalidUTF8: [UInt8] = [0x00, 0x1B, 0x27, 0x5C, 0xFF, 0xFE]
        try await session.execute("""
            INSERT INTO \(qualified("t_bin")) VALUES
              (1, \(SQLValueLiteral.hexLiteral(validUTF8))),
              (2, \(SQLValueLiteral.hexLiteral(invalidUTF8)))
            """)

        let data = try await exportCSV(table: "t_bin")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("0x414200"),
                      "合法 UTF-8 的二进制列也必须 hex 输出，实得：\(text)")
        XCTAssertTrue(text.contains("0x001B275CFFFE"), "实得：\(text)")
        XCTAssertFalse(text.contains("AB"), "不得把二进制列当文本原样输出")
    }

    /// 完整往返：导出 → 建新表 → 导入 → 二进制逐字节一致。
    func testBinaryRoundTripThroughImport() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_binsrc")) (id INT PRIMARY KEY, payload VARBINARY(32))
            """)
        let first: [UInt8] = [0x41, 0x42, 0x00]
        let second: [UInt8] = [0x00, 0x1B, 0x27, 0x5C, 0xFF, 0xFE]
        try await session.execute("""
            INSERT INTO \(qualified("t_binsrc")) VALUES
              (1, \(SQLValueLiteral.hexLiteral(first))),
              (2, \(SQLValueLiteral.hexLiteral(second)))
            """)

        let data = try await exportCSV(table: "t_binsrc")
        try await session.execute("""
            CREATE TABLE \(qualified("t_bindst")) (id INT PRIMARY KEY, payload VARBINARY(32))
            """)
        _ = try await importCSV(data, intoTable: "t_bindst")

        let result = try await firstResultSet("""
            SELECT payload FROM \(qualified("t_bindst")) ORDER BY id
            """)
        XCTAssertEqual(result?.rows.map { $0[0].bytes }, [first, second])
    }

    /// 导出中途取消：临时文件转为 `.partial`，正式目标文件不生成（docs/11 §3.1）。
    func testExportCancellationPreservesPartialFile() async throws {
        let stream = AsyncThrowingStream<[CellValue], Error> { continuation in
            continuation.yield([.text("1"), .text("a")])
            continuation.yield([.text("2"), .text("b")])
            continuation.finish()
        }
        let destination = fileSystem.temporaryDirectory.appendingPathComponent("cancelled.csv")

        do {
            try await CSVExporter(fileSystem: fileSystem, options: CSVCodec.Options()).write(
                to: destination,
                header: ["id", "name"],
                rows: stream,
                onProgress: { _, _ in },
                cancellation: { true }
            )
            XCTFail("取消导出应当抛 CSVExportError.incomplete")
        } catch let error as CSVExportError {
            guard case .incomplete(let partialURL) = error else {
                return XCTFail("期望 incomplete，实得 \(error)")
            }
            XCTAssertTrue(fileSystem.fileExists(at: partialURL), "已写入内容应保留为 .partial")
            XCTAssertEqual(partialURL.pathExtension, "partial")
            XCTAssertFalse(fileSystem.fileExists(at: destination), "正式目标文件不应生成")
        }
    }
}
