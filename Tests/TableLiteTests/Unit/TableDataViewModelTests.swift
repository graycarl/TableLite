import XCTest
@testable import TableLite

/// 表数据网格 ViewModel：分页、排序、选择、复制、列显隐、大字段两阶段加载。
///
/// 见 `docs/tech-designs/07-data-grid.md` §3。
@MainActor
final class TableDataViewModelTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    // MARK: 装配

    private func makeSession() async throws -> ConnectionSession {
        try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
    }

    private static let columns: [ColumnInfo] = [
        TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey),
        TestSupport.column("name", type: .varString),
        TestSupport.column("email", type: .varString),
    ]

    private func makeViewModel(
        session: ConnectionSession,
        columns: [ColumnInfo] = TableDataViewModelTests.columns,
        primaryKeyColumns: [String] = ["id"],
        rowCount: RowCountEstimate? = RowCountEstimate(approximate: 12_480)
    ) -> (TableDataViewModel, Tab) {
        let tab = session.openTableData(database: "app_dev", table: "users")
        let metadata = TableDataMetadata(
            columns: columns,
            tableInfo: TableInfo(database: "app_dev", name: "users", rowCountEstimate: 12_480),
            isView: false,
            primaryKeyColumns: primaryKeyColumns
        )
        let provider = FakeTableDataMetadataProvider(metadata: metadata, rowCount: rowCount)
        let viewModel = TableDataViewModel(
            session: session,
            tab: tab,
            metadataProvider: provider,
            preferences: harness.preferences,
            clock: harness.clock
        )
        return (viewModel, tab)
    }

    private func pageResponse(rowCount: Int, startIndex: Int = 1) -> (String, MySQLQueryResult) {
        let rows: [[String?]] = (0..<rowCount).map { offset in
            let number = startIndex + offset
            return ["\(number)", "name\(number)", "u\(number)@example.com"]
        }
        return (
            "FROM `app_dev`.`users`",
            .single(columns: ["id", "name", "email"], rows: rows)
        )
    }

    // MARK: 分页

    func testLoadsOnlyCurrentPageAndDetectsNext() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 301)])

        await viewModel.start()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.rows.count, 300)
        XCTAssertTrue(viewModel.hasNextPage)
        XCTAssertEqual(viewModel.pageState.offset, 0)
        // 只取 pageSize + 1 行，绝不整表拉取。
        let executed = await harness.mysql.executedSQL
        XCTAssertTrue(executed.contains { $0.contains("LIMIT 301") })

        // 翻到下一页会带 OFFSET。
        await harness.mysql.setResponses([pageResponse(rowCount: 300, startIndex: 301)])
        viewModel.goToNextPage()
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.pageIndex, 1)
        let second = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(second.contains("LIMIT 301 OFFSET 300"))
        XCTAssertEqual(viewModel.rows.first?.cells["id"]?.value, .text("301"))
    }

    func testSetPageSizeResetsToFirstPageAndPersistsPreference() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 301)])
        await viewModel.start()

        viewModel.goToNextPage()
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.pageIndex, 1)

        await harness.mysql.setResponses([pageResponse(rowCount: 100)])
        viewModel.setPageSize(1000)
        await viewModel.waitForPendingWork()

        XCTAssertEqual(viewModel.pageSize, 1000)
        XCTAssertEqual(viewModel.pageIndex, 0)
        XCTAssertEqual(harness.preferences.pageSize, 1000)
    }

    func testPageStatusTextMarksEstimate() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 300)])
        await viewModel.start()

        let text = viewModel.statusBarText ?? ""
        XCTAssertTrue(text.hasPrefix("行 1–300 / 约 12,480 行"))
        XCTAssertTrue(text.contains("第 1 页"))
    }

    func testDeepOffsetHint() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 100)])
        await viewModel.start()

        XCTAssertNil(viewModel.deepOffsetHint)
        viewModel.goToPage(400) // offset = 400 * 300 = 120000 > 100000
        await viewModel.waitForPendingWork()
        XCTAssertNotNil(viewModel.deepOffsetHint)
    }

    // MARK: 排序

    func testSortToggleCyclesAndGeneratesStableOrderBy() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.toggleSort(column: "name", additive: false)
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.sortOrders, [SortOrder(column: "name", direction: .ascending)])
        let asc = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(asc.contains("ORDER BY `name` ASC, `id` ASC"))

        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        viewModel.toggleSort(column: "name", additive: false)
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.sortOrders, [SortOrder(column: "name", direction: .descending)])

        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        viewModel.toggleSort(column: "name", additive: false)
        await viewModel.waitForPendingWork()
        XCTAssertTrue(viewModel.sortOrders.isEmpty)
        let none = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(none.contains("ORDER BY `id` ASC"))
        XCTAssertFalse(none.contains("ORDER BY `name`"))
    }

    func testAdditiveSortAppendsColumns() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.toggleSort(column: "name", additive: false)
        await viewModel.waitForPendingWork()
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        viewModel.toggleSort(column: "email", additive: true)
        await viewModel.waitForPendingWork()

        XCTAssertEqual(viewModel.sortOrders, [
            SortOrder(column: "name", direction: .ascending),
            SortOrder(column: "email", direction: .ascending),
        ])
    }

    // MARK: 列显隐与列宽

    func testColumnVisibility() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, tab) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.setColumnHidden("email", hidden: true)
        XCTAssertEqual(viewModel.hiddenColumns, ["email"])
        XCTAssertEqual(viewModel.visibleColumns.map(\.name), ["id", "name"])
        XCTAssertEqual(tab.hiddenColumns, ["email"])

        viewModel.setColumnHidden("email", hidden: false)
        XCTAssertTrue(viewModel.hiddenColumns.isEmpty)
        XCTAssertEqual(viewModel.visibleColumns.map(\.name), ["id", "name", "email"])
    }

    func testCannotHideLastVisibleColumn() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session, columns: [TestSupport.column("id", type: .long)])
        await harness.mysql.setResponses([pageResponse(rowCount: 1)])
        await viewModel.start()

        viewModel.setColumnHidden("id", hidden: true)
        XCTAssertEqual(viewModel.visibleColumns.map(\.name), ["id"])
    }

    // MARK: 选择

    func testSelectionDrivesInspector() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        let first = viewModel.rows[0].id
        viewModel.updateSelection(rowIDs: [first], focusedRowID: first, focusedColumn: "name")
        XCTAssertEqual(viewModel.inspectorRow?.id, first)
        XCTAssertEqual(viewModel.focusedColumn, "name")

        // 多选时不显示字段列表。
        viewModel.updateSelection(
            rowIDs: [viewModel.rows[0].id, viewModel.rows[1].id],
            focusedRowID: viewModel.rows[0].id,
            focusedColumn: "name"
        )
        XCTAssertNil(viewModel.inspectorRow)
    }

    // MARK: 复制

    func testCopyRowsAsTSVAndJSONAndInsert() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.start()

        let ids = [viewModel.rows[0].id, viewModel.rows[1].id]
        viewModel.updateSelection(rowIDs: ids, focusedRowID: ids[0], focusedColumn: "name")

        let tsv = viewModel.makeCopy(format: .rows).text
        XCTAssertEqual(tsv, "1\tname1\tu1@example.com\n2\tname2\tu2@example.com")

        let json = viewModel.makeCopy(format: .json).text
        XCTAssertTrue(json.hasPrefix("["))
        XCTAssertTrue(json.contains("\"name\": \"name1\""))

        let insert = viewModel.makeCopy(format: .sqlInsert).text
        XCTAssertTrue(insert.contains("INSERT INTO `app_dev`.`users`"))
        XCTAssertTrue(insert.contains("'name1'"))

        let cell = viewModel.makeCellCopy(rowID: ids[0], column: "name", format: .cellValue).text
        XCTAssertEqual(cell, "name1")
    }

    func testDefaultCopyUsesCellWhenFocused() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.start()

        let id = viewModel.rows[0].id
        viewModel.updateSelection(rowIDs: [id], focusedRowID: id, focusedColumn: "email")
        XCTAssertEqual(viewModel.makeDefaultCopy().text, "u1@example.com")
    }

    // MARK: 大字段两阶段加载

    func testTruncatedLargeColumnStaysMarkedAndFullValueIsLoadedOnDemand() async throws {
        harness.preferences.lazyLargeColumns = true
        harness.preferences.lazyLargeColumnThreshold = 256
        let session = try await makeSession()

        let contentColumn = TestSupport.column(
            "content",
            type: .blob,
            charset: 33,
            dataType: "text",
            columnType: "longtext"
        )
        let columns = [Self.columns[0], Self.columns[1], contentColumn]
        let (viewModel, _) = makeViewModel(session: session, columns: columns)

        let prefix = String(repeating: "a", count: 300)
        let pageResult = MySQLQueryResult.single(
            columns: ["id", "name", "content", "__mtl_len_2"],
            rows: [["1", "张三", prefix, "10000"]]
        )
        let fullResult = MySQLQueryResult.single(
            columns: ["id", "name", "content"],
            rows: [["1", "张三", prefix + "FULL"]]
        )
        await harness.mysql.setResponses([
            ("WHERE `id` =", fullResult),
            ("FROM `app_dev`.`users`", pageResult),
        ])

        await viewModel.start()

        let cell = viewModel.rows[0].cells["content"]
        XCTAssertEqual(cell?.isTruncated, true)
        XCTAssertEqual(cell?.totalByteCount, 10_000)
        XCTAssertNil(cell?.fullValue)
        XCTAssertTrue(cell?.needsFullValueLoad ?? false)

        let rowID = viewModel.rows[0].id
        viewModel.updateSelection(rowIDs: [rowID], focusedRowID: rowID, focusedColumn: "content")
        viewModel.requestFullRowLoad(force: true)
        await viewModel.waitForPendingWork()

        let loaded = viewModel.rows[0].cells["content"]
        XCTAssertNotNil(loaded?.fullValue)
        XCTAssertEqual(loaded?.fullValue, .text(prefix + "FULL"))
        XCTAssertFalse(loaded?.needsFullValueLoad ?? true)
    }

    func testNoPrimaryKeyCannotLocateRow() async throws {
        harness.preferences.lazyLargeColumns = true
        harness.preferences.lazyLargeColumnThreshold = 256
        let session = try await makeSession()

        let contentColumn = TestSupport.column(
            "content",
            type: .blob,
            charset: 33,
            dataType: "text",
            columnType: "longtext"
        )
        let (viewModel, _) = makeViewModel(
            session: session,
            columns: [Self.columns[1], contentColumn],
            primaryKeyColumns: []
        )
        let prefix = String(repeating: "b", count: 300)
        await harness.mysql.setResponses([
            ("FROM `app_dev`.`users`", .single(
                columns: ["name", "content", "__mtl_len_1"],
                rows: [["李四", prefix, "5000"]]
            )),
        ])
        await viewModel.start()

        let rowID = viewModel.rows[0].id
        XCTAssertNil(viewModel.rows[0].locator)
        viewModel.updateSelection(rowIDs: [rowID], focusedRowID: rowID, focusedColumn: "content")
        viewModel.requestFullRowLoad(force: true)
        await viewModel.waitForPendingWork()

        XCTAssertEqual(viewModel.fullRowError, "无法定位行以加载完整内容")
        XCTAssertFalse(viewModel.isEditable)
    }

    // MARK: 精确统计

    func testExactCountIsOnlyRunOnDemand() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        let before = await harness.mysql.executedSQL.filter { $0.contains("COUNT(*)") }
        XCTAssertTrue(before.isEmpty, "打开表时绝不能自动 COUNT(*)")

        await harness.mysql.setResponses([("COUNT(*)", .single(columns: ["__mtl_count"], rows: [["42"]]))])
        viewModel.runExactCount()
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.rowCountEstimate?.approximate, 42)
        XCTAssertEqual(viewModel.rowCountEstimate?.isExact, true)
    }
}

// MARK: - 假元数据来源

struct FakeTableDataMetadataProvider: TableDataMetadataProviding {
    let metadata: TableDataMetadata
    let rowCount: RowCountEstimate?

    func loadMetadata(database: String, table: String, forceRefresh: Bool) async throws -> TableDataMetadata {
        metadata
    }

    func loadRowCountEstimate(database: String, table: String, forceRefresh: Bool) async throws -> RowCountEstimate? {
        rowCount
    }
}
