import XCTest
@testable import TableLite

/// `TableDataLoader` 真库集成测试：分页 / 投影 / 大字段两阶段 / 无主键 / 过滤器。
///
/// 设计约束见 docs/tech-designs/07-data-grid.md §3。
final class TableDataLoaderIntegrationTests: MySQLIntegrationTestCase {

    override class var databaseName: String { "tablelite_it_data" }

    private func makeLoader() -> TableDataLoader {
        TableDataLoader(session: session, meta: MetaRepository(session: session, clock: LiveClock()))
    }

    private func request(pageIndex: Int = 0,
                         pageSize: Int = 300,
                         sort: [TableLite.SortDescriptor] = [],
                         filter: FilterSet = FilterSet()) -> TablePageRequest {
        TablePageRequest(schema: Self.databaseName,
                         table: "t",
                         pageIndex: pageIndex,
                         pageSize: pageSize,
                         sort: sort,
                         filter: filter)
    }

    private func intValue(_ row: TableDataRow, _ index: Int) -> Int? {
        Int(row.values[index].displayText)
    }

    // MARK: 分页

    func testPaginationHasNextPageAndStablePrimaryKeyOrder() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_page")) (
              id INT PRIMARY KEY,
              v VARCHAR(20)
            )
            """)
        let tuples = (1...350).map { "(\($0), 'v\($0)')" }.joined(separator: ", ")
        try await session.execute("INSERT INTO \(qualified("t_page")) (id, v) VALUES \(tuples)")

        let ref = TableRef(database: Self.databaseName, table: "t_page")
        let structure = try await tableStructure("t_page")
        let loader = makeLoader()

        let page0 = try await loader.loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 300),
            lazyLarge: false, largeThreshold: 4096
        )
        XCTAssertEqual(page0.rows.count, 300)
        XCTAssertTrue(page0.hasNextPage, "350 行、每页 300 时第 1 页应当有下一页")
        XCTAssertEqual(page0.primaryKeyColumns, ["id"])
        XCTAssertTrue(page0.hasPrimaryKey)
        XCTAssertEqual(intValue(page0.rows.first!, 0), 1)
        XCTAssertEqual(intValue(page0.rows.last!, 0), 300)

        let page1 = try await loader.loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 1, pageSize: 300),
            lazyLarge: false, largeThreshold: 4096
        )
        XCTAssertEqual(page1.rows.count, 50, "第 2 页只剩 50 行")
        XCTAssertFalse(page1.hasNextPage)
        XCTAssertEqual(intValue(page1.rows.first!, 0), 301)
        XCTAssertEqual(intValue(page1.rows.last!, 0), 350)

        // 翻页拼起来不重不漏
        let allIDs = (page0.rows + page1.rows).compactMap { intValue($0, 0) }
        XCTAssertEqual(allIDs, Array(1...350))
    }

    func testUserSortAppendsPrimaryKeyForStableOrder() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_sort")) (
              id INT PRIMARY KEY,
              grp INT NOT NULL,
              v VARCHAR(10)
            )
            """)
        // grp 全部相同 → 排序必须靠主键保证稳定
        let tuples = (1...6).map { "(\($0), 1, 'v\($0)')" }.joined(separator: ", ")
        try await session.execute("INSERT INTO \(qualified("t_sort")) (id, grp, v) VALUES \(tuples)")

        let ref = TableRef(database: Self.databaseName, table: "t_sort")
        let structure = try await tableStructure("t_sort")
        let loader = makeLoader()

        let page = try await loader.loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 10,
                             sort: [TableLite.SortDescriptor(column: "grp", descending: true)]),
            lazyLarge: false, largeThreshold: 4096
        )
        XCTAssertEqual(page.rows.compactMap { intValue($0, 0) }, [1, 2, 3, 4, 5, 6],
                       "次级排序键主键应保证顺序稳定")
    }

    // MARK: 投影来自 information_schema 列清单

    func testProjectionFollowsInformationSchemaColumnOrder() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_proj")) (
              b VARCHAR(5),
              a INT,
              c TEXT,
              id INT PRIMARY KEY
            )
            """)
        try await session.execute("INSERT INTO \(qualified("t_proj")) VALUES ('x', 7, 'hello', 1)")

        let structure = try await tableStructure("t_proj")
        XCTAssertEqual(structure.columns.map(\.name), ["b", "a", "c", "id"],
                       "列顺序必须来自 information_schema 的 ORDINAL_POSITION")

        let ref = TableRef(database: Self.databaseName, table: "t_proj")
        let page = try await makeLoader().loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 10),
            lazyLarge: false, largeThreshold: 4096
        )
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(row.values.map(\.displayText), ["x", "7", "hello", "1"])
    }

    // MARK: 大字段两阶段加载

    func testLargeFieldTwoPhaseLoadWithTextAndBinary() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_large")) (
              id INT PRIMARY KEY,
              big LONGTEXT,
              raw LONGBLOB
            )
            """)

        let text = String(repeating: "abcdefgh", count: 640) // 5120 字符
        let binary = (0..<5120).map { UInt8($0 % 256) }       // 含 \0
        let literalizer = await session.literalizer()
        let textLiteral = SQLValueLiteral.literal(.text(text), kind: .text, using: literalizer)
        let binaryLiteral = SQLValueLiteral.hexLiteral(binary)
        try await session.execute("""
            INSERT INTO \(qualified("t_large")) (id, big, raw)
            VALUES (1, \(textLiteral), \(binaryLiteral))
            """)

        let ref = TableRef(database: Self.databaseName, table: "t_large")
        let structure = try await tableStructure("t_large")
        let loader = makeLoader()

        let page = try await loader.loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 10),
            lazyLarge: true, largeThreshold: 4096
        )
        let row = try XCTUnwrap(page.rows.first)
        let bigIndex = try XCTUnwrap(structure.columns.firstIndex { $0.name == "big" })
        let rawIndex = try XCTUnwrap(structure.columns.firstIndex { $0.name == "raw" })

        XCTAssertEqual(row.truncatedLengths["big"], 5120)
        XCTAssertEqual(row.values[bigIndex].byteCount, 4096, "首屏只取前 4096 个字符")
        XCTAssertEqual(row.values[bigIndex].bytes, Array(text.utf8.prefix(4096)))

        XCTAssertEqual(row.truncatedLengths["raw"], 5120)
        XCTAssertEqual(row.values[rawIndex].byteCount, 4096)
        XCTAssertEqual(row.values[rawIndex].bytes, Array(binary.prefix(4096)))

        // 二次加载取回完整值
        let locator = RowLocator(columns: ["id"], values: [.text("1")])
        let full = try await loader.loadFullValues(
            ref: ref, structure: structure, locator: locator, columns: structure.columns
        )
        XCTAssertEqual(full["big"]?.bytes, Array(text.utf8))
        XCTAssertEqual(full["raw"]?.bytes, binary)
        XCTAssertEqual(full["id"]?.displayText, "1")
    }

    func testLoadFullValuesThrowsRowMissing() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_missing")) (id INT PRIMARY KEY, big LONGTEXT)
            """)
        let ref = TableRef(database: Self.databaseName, table: "t_missing")
        let structure = try await tableStructure("t_missing")

        do {
            _ = try await makeLoader().loadFullValues(
                ref: ref, structure: structure,
                locator: RowLocator(columns: ["id"], values: [.text("999")]),
                columns: structure.columns
            )
            XCTFail("行不存在时应当抛 rowMissing")
        } catch let error as TableDataLoaderError {
            XCTAssertEqual(error, .rowMissing)
        }
    }

    // MARK: 无主键

    func testNoPrimaryKeyTableOmitsOrderByAndMarksNotEditable() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_nopk")) (v INT, w VARCHAR(5))
            """)
        try await session.execute("INSERT INTO \(qualified("t_nopk")) VALUES (1, 'a'), (2, 'b')")

        let ref = TableRef(database: Self.databaseName, table: "t_nopk")
        let structure = try await tableStructure("t_nopk")
        XCTAssertTrue(structure.primaryKeyColumns.isEmpty)
        XCTAssertFalse(structure.isEditableStructure)

        let literalizer = await session.literalizer()
        let sql = try TableDataQueryBuilder.pageSQL(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 10),
            lazyLarge: false, largeThreshold: 4096, literalizer: literalizer
        )
        XCTAssertFalse(sql.uppercased().contains("ORDER BY"), "无主键表不得写 ORDER BY，实得：\(sql)")

        let page = try await makeLoader().loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 10),
            lazyLarge: false, largeThreshold: 4096
        )
        XCTAssertFalse(page.hasPrimaryKey)
        XCTAssertEqual(page.rows.count, 2)
    }

    // MARK: 过滤器

    func testExactPageSizeHasNoNextPage() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_exact")) (id INT PRIMARY KEY, v INT)
            """)
        let tuples = (1...300).map { "(\($0), \($0))" }.joined(separator: ",")
        try await session.execute("INSERT INTO \(qualified("t_exact")) (id, v) VALUES \(tuples)")

        let ref = TableRef(database: Self.databaseName, table: "t_exact")
        let structure = try await tableStructure("t_exact")
        let page = try await makeLoader().loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 300),
            lazyLarge: false, largeThreshold: 4096
        )
        XCTAssertEqual(page.rows.count, 300)
        XCTAssertFalse(page.hasNextPage, "恰好一页时不应误报下一页")
    }

    func testStringPrimaryKeyWithQuoteIsEscapedInFullValueLocator() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_quote")) (
              code VARCHAR(64) PRIMARY KEY,
              body LONGTEXT
            )
            """)
        let key = "O'Reilly"
        let literalizer = await session.literalizer()
        let keyLiteral = SQLValueLiteral.literal(.text(key), kind: .text, using: literalizer)
        let body = String(repeating: "z", count: 5000)
        let bodyLiteral = SQLValueLiteral.literal(.text(body), kind: .text, using: literalizer)
        try await session.execute("""
            INSERT INTO \(qualified("t_quote")) (code, body) VALUES (\(keyLiteral), \(bodyLiteral))
            """)

        let ref = TableRef(database: Self.databaseName, table: "t_quote")
        let structure = try await tableStructure("t_quote")
        let loader = makeLoader()
        let page = try await loader.loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 10),
            lazyLarge: true, largeThreshold: 4096
        )
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(row.truncatedLengths["body"], 5000)

        let locator = RowLocator(columns: ["code"], values: [.text(key)])
        let full = try await loader.loadFullValues(ref: ref, structure: structure,
                                                   locator: locator, columns: structure.columns)
        XCTAssertEqual(full["code"]?.displayText, key)
        XCTAssertEqual(full["body"]?.bytes, Array(body.utf8))
    }

    func testFilterWhereClauseApplies() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_filter")) (
              id INT PRIMARY KEY,
              name VARCHAR(20),
              n INT
            )
            """)
        try await session.execute("""
            INSERT INTO \(qualified("t_filter")) VALUES
              (1, 'bob', 10), (2, 'bobby', 20), (3, 'carol', 30), (4, 'alice', 40)
            """)

        var filter = FilterSet()
        filter.conditions = [
            FilterCondition(column: "name", op: .contains, value: "bo"),
            FilterCondition(column: "n", op: .greaterThanOrEqual, value: "20"),
        ]
        filter.logic = .all

        let ref = TableRef(database: Self.databaseName, table: "t_filter")
        let structure = try await tableStructure("t_filter")
        let page = try await makeLoader().loadPage(
            ref: ref, structure: structure,
            request: request(pageIndex: 0, pageSize: 10, filter: filter),
            lazyLarge: false, largeThreshold: 4096
        )
        XCTAssertEqual(page.rows.compactMap { intValue($0, 0) }, [2])

        // 精确统计走同一份 WHERE
        let count = try await MetaRepository(session: session, clock: LiveClock())
            .preciseCount(ref, whereClause: FilterSQLBuilder.build(filter, columns: structure.columns,
                                                                   using: await session.literalizer()).sql)
        XCTAssertEqual(count, 1)
    }
}
