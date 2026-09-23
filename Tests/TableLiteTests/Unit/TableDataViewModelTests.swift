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

    // MARK: 显示条数

    func testLoadsOnlyRowLimit() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 300)])

        await viewModel.start()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.rows.count, 300)
        // 只取前 N 行，不分页、不带 OFFSET。
        let executed = await harness.mysql.executedSQL
        XCTAssertTrue(executed.contains { $0.contains("LIMIT 300") })
        XCTAssertFalse(executed.contains { $0.contains("OFFSET") })
    }

    func testSetRowLimitReloadsAndPersistsPreference() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 300)])
        await viewModel.start()

        await harness.mysql.setResponses([pageResponse(rowCount: 1000)])
        viewModel.setRowLimit(1000)
        await viewModel.waitForPendingWork()

        XCTAssertEqual(viewModel.rowLimit, 1000)
        XCTAssertEqual(harness.preferences.rowLimit, 1000)
        XCTAssertEqual(viewModel.rows.count, 1000)
        let last = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(last.contains("LIMIT 1000"))
    }

    func testStatusTextMarksEstimate() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 300)])
        await viewModel.start()

        let text = viewModel.statusBarText ?? ""
        XCTAssertTrue(text.hasPrefix("显示 300 行 / 约 12,480 行"))
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

    // MARK: 自动查询不污染历史（`specs/06-query-editor.md` §5）

    func testAutomaticQueriesAreNotRecordedInHistory() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        let afterPage = try await harness.history.recent(connectionID: session.id)
        XCTAssertTrue(afterPage.isEmpty, "分页查询不得写入查询历史")

        await harness.mysql.setResponses([("COUNT(*)", .single(columns: ["__mtl_count"], rows: [["42"]]))])
        viewModel.runExactCount()
        await viewModel.waitForPendingWork()
        let afterCount = try await harness.history.recent(connectionID: session.id)
        XCTAssertTrue(afterCount.isEmpty, "精确统计不得写入查询历史")
    }

    // MARK: 列过滤器 toggle（`manual/12`）

    func testPresentColumnFilterToggles() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.start()

        XCTAssertFalse(viewModel.isColumnFilterPresented)
        viewModel.presentColumnFilter()
        XCTAssertTrue(viewModel.isColumnFilterPresented)
        viewModel.presentColumnFilter()
        XCTAssertFalse(viewModel.isColumnFilterPresented)
    }

    // MARK: 大字段实际大小进状态栏（`specs/03-data-browsing.md` §4）

    func testStatusBarShowsLargeFieldActualSize() async throws {
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
        let (viewModel, _) = makeViewModel(session: session, columns: [Self.columns[0], Self.columns[1], contentColumn])
        let prefix = String(repeating: "a", count: 300)
        await harness.mysql.setResponses([
            ("FROM `app_dev`.`users`", .single(
                columns: ["id", "name", "content", "__mtl_len_2"],
                rows: [["1", "张三", prefix, "1258291"]]
            )),
        ])
        await viewModel.start()

        XCTAssertEqual(viewModel.largeFieldSizeSummary, "content 1.2 MB")
        XCTAssertTrue(viewModel.statusBarText?.contains("content 1.2 MB") ?? false)
    }

    func testStatusBarHasNoLargeFieldSummaryWithoutTruncation() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.start()

        XCTAssertNil(viewModel.largeFieldSizeSummary)
        XCTAssertFalse(viewModel.statusBarText?.contains("MB") ?? false)
    }

    /// 耗时阈值口径在 `WorkspaceStatusText.tableDataSummary`，`statusBarText` 不再拼接耗时
    /// （`specs/12-feedback.md` §6）。
    func testStatusBarTextOmitsQueryDuration() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.start()

        XCTAssertFalse(viewModel.statusBarText?.contains(" ms") ?? false)
    }

    func testHasActiveFilterTracksAppliedFilter() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.start()

        XCTAssertFalse(viewModel.hasActiveFilter)

        viewModel.setFilter(FilterState(
            conditions: [FilterCondition(column: "name", op: .equal, value: "张三")],
            isVisible: true
        ))
        await viewModel.waitForPendingWork()
        XCTAssertTrue(viewModel.hasActiveFilter)

        viewModel.setFilter(nil)
        await viewModel.waitForPendingWork()
        XCTAssertFalse(viewModel.hasActiveFilter)
    }

    // MARK: 有未提交改动时的排序 / 刷新提示（`specs/04-data-editing.md` §12）

    func testSortWithPendingChangesShowsToast() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.start()
        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("新名"))

        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        viewModel.toggleSort(column: "name", additive: false)
        XCTAssertEqual(viewModel.copyNotice, "改变排序会重新加载数据，你的修改会保留在暂存区")
        await viewModel.waitForPendingWork()
    }

    func testRefreshWithPendingChangesShowsToast() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.start()
        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("新名"))

        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        await viewModel.refresh()
        XCTAssertEqual(viewModel.copyNotice, "刷新会重新加载数据，你的修改会保留在暂存区")
    }
}

// MARK: - 外键跳转（`specs/03-data-browsing.md` §10）

/// `ForeignKeyJumpResolver`：从行 + 列元数据推导「库 / 表 / 列 / 字面量」。纯函数。
final class ForeignKeyJumpResolverTests: XCTestCase {

    private let idColumn = TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey)
    private let userIdColumn = TestSupport.column("user_id", type: .long)
    private let nameColumn = TestSupport.column("name", type: .varString)
    private let tokenColumn = TestSupport.column("token", type: .blob, charset: 63)

    private func foreignKey(
        columns: [String],
        database: String? = nil,
        table: String = "users",
        referencedColumns: [String] = ["id"]
    ) -> ForeignKeyInfo {
        ForeignKeyInfo(
            name: "fk",
            columns: columns,
            referencedDatabase: database,
            referencedTable: table,
            referencedColumns: referencedColumns
        )
    }

    func testSingleColumnForeignKeyProducesTarget() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "user_id",
            columns: [idColumn, userIdColumn],
            values: ["user_id": .integer(42)],
            foreignKeys: [foreignKey(columns: ["user_id"])]
        )
        XCTAssertEqual(target?.database, "app_dev")
        XCTAssertEqual(target?.table, "users")
        XCTAssertEqual(target?.whereClause, "`id` = 42")
    }

    func testCrossDatabaseUsesReferencedSchema() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "user_id",
            columns: [idColumn, userIdColumn],
            values: ["user_id": .integer(7)],
            foreignKeys: [foreignKey(columns: ["user_id"], database: "app_meta")]
        )
        XCTAssertEqual(target?.database, "app_meta")
        XCTAssertEqual(target?.table, "users")
        XCTAssertEqual(target?.whereClause, "`id` = 7")
    }

    func testNullValueDisablesJump() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "user_id",
            columns: [idColumn, userIdColumn],
            values: ["user_id": .null],
            foreignKeys: [foreignKey(columns: ["user_id"])]
        )
        XCTAssertNil(target)
    }

    func testMissingValueDisablesJump() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "user_id",
            columns: [idColumn, userIdColumn],
            values: [:],
            foreignKeys: [foreignKey(columns: ["user_id"])]
        )
        XCTAssertNil(target)
    }

    func testNonForeignKeyColumnDisablesJump() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "name",
            columns: [idColumn, nameColumn],
            values: ["name": .text("张三")],
            foreignKeys: [foreignKey(columns: ["user_id"])]
        )
        XCTAssertNil(target)
    }

    func testStringLiteralEscapedForDefaultMode() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "name",
            columns: [nameColumn],
            values: ["name": .text("O'Brien")],
            foreignKeys: [foreignKey(columns: ["name"], table: "users", referencedColumns: ["name"])],
            escaping: .mysqlDefault
        )
        XCTAssertEqual(target?.keys.first?.column, "name")
        XCTAssertEqual(target?.keys.first?.literal, "'O\\'Brien'")
    }

    func testStringLiteralEscapedForNoBackslashEscapes() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "name",
            columns: [nameColumn],
            values: ["name": .text("O'Brien")],
            foreignKeys: [foreignKey(columns: ["name"], table: "users", referencedColumns: ["name"])],
            escaping: .noBackslashEscapes
        )
        XCTAssertEqual(target?.keys.first?.literal, "'O''Brien'")
    }

    func testNumericTextValueIsNotQuoted() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "user_id",
            columns: [idColumn, userIdColumn],
            values: ["user_id": .text("42")],
            foreignKeys: [foreignKey(columns: ["user_id"])]
        )
        XCTAssertEqual(target?.whereClause, "`id` = 42")
    }

    func testBinaryValueUsesHexLiteral() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "token",
            columns: [tokenColumn],
            values: ["token": .binary(Data([0xDE, 0xAD, 0xBE, 0xEF]))],
            foreignKeys: [foreignKey(columns: ["token"], table: "tokens", referencedColumns: ["token"])]
        )
        XCTAssertEqual(target?.whereClause, "`token` = 0xDEADBEEF")
    }

    func testCompositeForeignKeyJoinsAllKeys() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "user_id",
            columns: [idColumn, userIdColumn, nameColumn],
            values: ["user_id": .integer(1), "name": .text("a")],
            foreignKeys: [foreignKey(columns: ["user_id", "name"], table: "users", referencedColumns: ["id", "name"])]
        )
        XCTAssertEqual(target?.whereClause, "`id` = 1 AND `name` = 'a'")
    }

    func testCompositeForeignKeyWithNullComponentDisablesJump() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "user_id",
            columns: [idColumn, userIdColumn, nameColumn],
            values: ["user_id": .integer(1), "name": .null],
            foreignKeys: [foreignKey(columns: ["user_id", "name"], table: "users", referencedColumns: ["id", "name"])]
        )
        XCTAssertNil(target)
    }

    func testColumnCountMismatchDisablesJump() {
        let target = ForeignKeyJumpResolver.target(
            sourceDatabase: "app_dev",
            clickedColumn: "user_id",
            columns: [idColumn, userIdColumn],
            values: ["user_id": .integer(1)],
            foreignKeys: [foreignKey(columns: ["user_id"], referencedColumns: [])]
        )
        XCTAssertNil(target)
    }
}

/// `TableDataViewModel.openForeignKey`：打开新标签并带入「引用列 = 本行值」过滤。
@MainActor
final class ForeignKeyNavigationTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    private func makeViewModel(
        session: ConnectionSession,
        foreignKeys: [ForeignKeyInfo],
        rows: [[String?]]
    ) async -> (TableDataViewModel, Tab) {
        harness.preferences.lazyLargeColumns = false
        let tab = session.openTableData(database: "app_dev", table: "orders")
        let columns = [
            TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey),
            TestSupport.column("user_id", type: .long),
        ]
        let metadata = TableDataMetadata(
            columns: columns,
            tableInfo: TableInfo(database: "app_dev", name: "orders", rowCountEstimate: Int64(rows.count)),
            isView: false,
            primaryKeyColumns: ["id"],
            foreignKeyColumns: ["user_id"],
            foreignKeys: foreignKeys
        )
        let provider = FakeTableDataMetadataProvider(metadata: metadata, rowCount: RowCountEstimate(approximate: Int64(rows.count)))
        let viewModel = TableDataViewModel(
            session: session,
            tab: tab,
            metadataProvider: provider,
            preferences: harness.preferences,
            clock: harness.clock
        )
        await harness.mysql.setResponses([
            ("FROM `app_dev`.`orders`", .single(columns: ["id", "user_id"], rows: rows)),
        ])
        await viewModel.start()
        return (viewModel, tab)
    }

    func testOpensNewTabWithRawEqualityFilter() async throws {
        let session = try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
        let foreignKey = ForeignKeyInfo(
            name: "fk_orders_user",
            columns: ["user_id"],
            referencedDatabase: "app_meta",
            referencedTable: "users",
            referencedColumns: ["id"]
        )
        let (viewModel, _) = await makeViewModel(session: session, foreignKeys: [foreignKey], rows: [["1", "42"]])
        let before = session.tabs.count

        await viewModel.openForeignKey(rowID: viewModel.rows[0].id, column: "user_id")

        XCTAssertEqual(session.tabs.count, before + 1)
        let opened = try XCTUnwrap(session.tabs.last)
        XCTAssertEqual(opened.kind, .tableData(database: "app_meta", table: "users"))
        XCTAssertEqual(opened.initialFilter?.rawWhere, "`id` = 42")
        XCTAssertEqual(opened.initialFilter?.isRawMode, true)
        XCTAssertEqual(opened.initialFilter?.isVisible, true)
        // 跳转带入的过滤不是「按表记住的过滤」，不应污染用户的记忆。
        XCTAssertNil(session.tableFilter(database: "app_meta", table: "users"))
    }

    func testNullForeignKeyValueDoesNotOpenTab() async throws {
        let session = try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
        let foreignKey = ForeignKeyInfo(
            name: "fk_orders_user",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"]
        )
        let (viewModel, _) = await makeViewModel(session: session, foreignKeys: [foreignKey], rows: [["1", nil]])
        let before = session.tabs.count

        await viewModel.openForeignKey(rowID: viewModel.rows[0].id, column: "user_id")

        XCTAssertEqual(session.tabs.count, before)
        XCTAssertEqual(viewModel.copyNotice, "外键值为 NULL，无法跳转")
    }

    /// 外键列被截断时不能用截断值拼条件：先二次加载完整值再跳转（`07-data-grid.md` §3.1）。
    func testTruncatedForeignKeyValueLoadsFullValueBeforeJump() async throws {
        harness.preferences.lazyLargeColumns = true
        harness.preferences.lazyLargeColumnThreshold = 256
        let session = try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
        let tab = session.openTableData(database: "app_dev", table: "orders")
        let foreignKey = ForeignKeyInfo(
            name: "fk_orders_user",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"]
        )
        let columns = [
            TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey),
            TestSupport.column("user_id", type: .blob, charset: 33, dataType: "text", columnType: "longtext"),
        ]
        let metadata = TableDataMetadata(
            columns: columns,
            tableInfo: TableInfo(database: "app_dev", name: "orders", rowCountEstimate: 1),
            isView: false,
            primaryKeyColumns: ["id"],
            foreignKeyColumns: ["user_id"],
            foreignKeys: [foreignKey]
        )
        let provider = FakeTableDataMetadataProvider(metadata: metadata, rowCount: RowCountEstimate(approximate: 1))
        let viewModel = TableDataViewModel(
            session: session,
            tab: tab,
            metadataProvider: provider,
            preferences: harness.preferences,
            clock: harness.clock
        )
        let prefix = String(repeating: "a", count: 300)
        await harness.mysql.setResponses([
            ("WHERE `id` =", .single(columns: ["id", "user_id"], rows: [["1", "u-42"]])),
            ("FROM `app_dev`.`orders`", .single(
                columns: ["id", "user_id", "__mtl_len_1"],
                rows: [["1", prefix, "10000"]]
            )),
        ])
        await viewModel.start()
        XCTAssertEqual(viewModel.rows[0].cells["user_id"]?.isTruncated, true)

        await viewModel.openForeignKey(rowID: viewModel.rows[0].id, column: "user_id")

        let opened = try XCTUnwrap(session.tabs.last)
        XCTAssertEqual(opened.kind, .tableData(database: "app_dev", table: "users"))
        XCTAssertEqual(opened.initialFilter?.rawWhere, "`id` = 'u-42'")
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
