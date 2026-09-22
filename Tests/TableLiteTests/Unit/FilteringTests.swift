import XCTest
@testable import TableLite

// MARK: - 纯函数：快速过滤 SQL 生成 / 组合 / 状态模型

/// 快速过滤与状态模型（`docs/tech-designs/09-filtering.md` §1.3、§1.4）。
final class FilterQuickFilterTests: XCTestCase {

    private let columns: [ColumnInfo] = [
        TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63),
        TestSupport.column("name", type: .varString),
        TestSupport.column("email", type: .varString),
    ]

    // MARK: 快速过滤

    func testQuickFilterClauseJoinsVisibleColumnsWithOr() {
        let clause = FilterSQLBuilder.quickFilterClause("张", columns: [columns[1], columns[2]])
        XCTAssertEqual(clause, "(`name` LIKE '%张%' ESCAPE '\\\\' OR `email` LIKE '%张%' ESCAPE '\\\\')")
    }

    func testQuickFilterClauseEscapesWildcards() {
        let clause = FilterSQLBuilder.quickFilterClause("a_b%", columns: [columns[1]])
        XCTAssertEqual(clause, "(`name` LIKE '%a\\\\_b\\\\%%' ESCAPE '\\\\')")
    }

    func testQuickFilterClauseEmptyOrNoColumnsIsNil() {
        XCTAssertNil(FilterSQLBuilder.quickFilterClause("   ", columns: columns))
        XCTAssertNil(FilterSQLBuilder.quickFilterClause("x", columns: []))
    }

    func testQuickFilterClauseSkipsBinaryColumns() {
        let binary = TestSupport.column("payload", type: .blob, charset: 63)
        XCTAssertNil(FilterSQLBuilder.quickFilterClause("x", columns: [binary]))
    }

    // MARK: 组合

    func testCombine() {
        XCTAssertEqual(FilterSQLBuilder.combine("A", "B"), "(A) AND (B)")
        XCTAssertEqual(FilterSQLBuilder.combine("A", nil), "A")
        XCTAssertEqual(FilterSQLBuilder.combine(nil, "B"), "B")
        XCTAssertNil(FilterSQLBuilder.combine(nil, nil))
    }

    // MARK: 状态模型

    func testQuickFilterKeepsStateActive() {
        var state = FilterState()
        XCTAssertFalse(state.isActive)
        state.quickFilter = "张"
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.hasQuickFilter)
        state.reset()
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.quickFilter, "")
    }

    func testFilterStateRoundTripsQuickFilter() throws {
        var state = FilterState(conditions: [
            FilterCondition(column: "name", op: .contains, value: "张"),
        ], isVisible: true, quickFilter: "abc")
        state.combination = .any
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(FilterState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    /// 向前兼容（`02-persistence.md` §9）：旧数据没有 `quickFilter` 字段时按空串处理。
    func testFilterStateDecodesLegacyJSONWithoutQuickFilter() throws {
        let json = #"{"conditions":[],"combination":"all","rawWhere":"","isRawMode":false,"isVisible":true}"#
        let state = try JSONDecoder().decode(FilterState.self, from: Data(json.utf8))
        XCTAssertEqual(state.quickFilter, "")
        XCTAssertTrue(state.isVisible)
    }
}

// MARK: - ViewModel：应用 / 错误 / Raw / 防抖 / 持久化 / 列显隐

/// 行过滤器与 ViewModel 的对接（`docs/tech-designs/09-filtering.md` §1、§3、§1.6）。
@MainActor
final class TableDataFilteringTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
        TableDataViewModel.quickFilterDebounceDelay = .zero
    }

    override func tearDown() async throws {
        TableDataViewModel.quickFilterDebounceDelay = .milliseconds(250)
        harness?.clean()
        harness = nil
    }

    private static let columns: [ColumnInfo] = [
        TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey),
        TestSupport.column("name", type: .varString),
        TestSupport.column("status", type: .enumeration, columnType: "enum('draft','published')"),
    ]

    private func makeSession() async throws -> ConnectionSession {
        try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
    }

    private func makeViewModel(session: ConnectionSession) -> (TableDataViewModel, Tab) {
        let tab = session.openTableData(database: "app_dev", table: "users")
        let metadata = TableDataMetadata(
            columns: Self.columns,
            tableInfo: TableInfo(database: "app_dev", name: "users", rowCountEstimate: 12_480),
            isView: false,
            primaryKeyColumns: ["id"]
        )
        let provider = FakeTableDataMetadataProvider(metadata: metadata, rowCount: RowCountEstimate(approximate: 12_480))
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
            return ["\(number)", "name\(number)", "draft"]
        }
        return ("FROM `app_dev`.`users`", .single(columns: ["id", "name", "status"], rows: rows))
    }

    // MARK: 应用与分页

    func testApplyFilterResetsToFirstPageAndGeneratesWhere() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, tab) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 301)])
        await viewModel.start()

        viewModel.goToNextPage()
        await viewModel.waitForPendingWork()
        XCTAssertEqual(viewModel.pageIndex, 1)

        viewModel.addFilterCondition(column: "name", op: .contains, value: "张")
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()

        XCTAssertEqual(viewModel.pageIndex, 0)
        XCTAssertNil(viewModel.filterError)
        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(sql.contains("WHERE (`name` LIKE '%张%'"), sql)
        XCTAssertNotNil(tab.filter)
    }

    func testApplyFilterWithPendingChangesStillReloads() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        // 制造一条暂存（编辑字段栏）。
        let firstID = viewModel.rows[0].id
        await viewModel.applyInspectorEdit(rowID: firstID, column: "name", value: .text("改过的"))
        XCTAssertTrue(viewModel.hasPendingChanges)

        viewModel.addFilterCondition(column: "name", op: .equal, value: "name2")
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()

        XCTAssertNil(viewModel.filterError)
        XCTAssertTrue(viewModel.hasPendingChanges, "过滤不应清掉暂存")
        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(sql.contains("WHERE (`name` = 'name2')"), sql)
    }

    // MARK: 错误处理

    func testUnknownColumnReportsErrorAndDoesNotApply() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        let id = viewModel.addFilterCondition(column: "missing", op: .equal, value: "1")
        let queriesBefore = await harness.mysql.executedSQL.count
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()

        XCTAssertNotNil(viewModel.filterError)
        XCTAssertTrue(viewModel.isFilterConditionErrored(id))
        XCTAssertNil(viewModel.filter)
        let queriesAfter = await harness.mysql.executedSQL.count
        XCTAssertEqual(queriesAfter, queriesBefore, "校验失败时不应下发查询")
    }

    func testIncompleteConditionIsSkipped() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.addFilterCondition(column: "name", op: .equal, value: "   ")
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()

        XCTAssertNil(viewModel.filterError)
        XCTAssertTrue(viewModel.filter?.activeConditions.isEmpty ?? true)
        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertFalse(sql.contains("WHERE"), sql)
    }

    func testEmptyInListReportsError() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.addFilterCondition(column: "id", op: .inList, value: " , ")
        viewModel.applyFilter()
        XCTAssertEqual(viewModel.filterError, "「id」的在列表中条件没有填写任何值")
    }

    // MARK: Raw 模式

    func testRawAndConditionModesAreMutuallyExclusive() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.addFilterCondition(column: "name", op: .equal, value: "a")
        XCTAssertFalse(viewModel.filterDraft.conditions.isEmpty)

        viewModel.switchFilterToRawMode()
        XCTAssertTrue(viewModel.filterDraft.isRawMode)
        XCTAssertTrue(viewModel.filterDraft.conditions.isEmpty)

        viewModel.setRawWhere("id > 10")
        viewModel.switchFilterToConditionsMode()
        XCTAssertFalse(viewModel.filterDraft.isRawMode)
        XCTAssertEqual(viewModel.filterDraft.rawWhere, "")
    }

    func testRawModeAppliesAndRejectsSemicolon() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.switchFilterToRawMode()
        viewModel.setRawWhere("id IN (1, 2, 3)")
        await harness.mysql.setResponses([pageResponse(rowCount: 3)])
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()
        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(sql.contains("WHERE id IN (1, 2, 3)"), sql)

        viewModel.setRawWhere("id = 1; DROP TABLE t")
        viewModel.applyFilter()
        XCTAssertEqual(viewModel.filterError, "高级条件里不能包含分号「;」")
    }

    // MARK: 快速过滤

    func testQuickFilterCombinesWithRowConditions() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.addFilterCondition(column: "status", op: .equal, value: "draft")
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()

        viewModel.setQuickFilter("张")
        await viewModel.waitForPendingWork()

        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(sql.contains("`status` = 'draft'"), sql)
        XCTAssertTrue(sql.contains("`name` LIKE '%张%'"), sql)
        XCTAssertTrue(sql.contains(") AND ("), sql)
    }

    func testQuickFilterIsDebounced() async throws {
        TableDataViewModel.quickFilterDebounceDelay = .milliseconds(200)
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()
        let before = await harness.mysql.executedSQL.count

        viewModel.setQuickFilter("张")
        let immediate = await harness.mysql.executedSQL.count
        XCTAssertEqual(immediate, before, "防抖期内不应立即发查询")

        await viewModel.waitForPendingWork()
        let after = await harness.mysql.executedSQL.count
        XCTAssertGreaterThan(after, before)
        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(sql.contains("LIKE '%张%'"), sql)
    }

    func testClearQuickFilterReloadsUnfiltered() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.setQuickFilter("张")
        await viewModel.waitForPendingWork()
        viewModel.clearQuickFilter()
        await viewModel.waitForPendingWork()

        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertFalse(sql.contains("LIKE"), sql)
    }

    // MARK: 快速筛选入口

    func testByColumnAddsEmptyEqualConditionAndFocuses() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.applyQuickFilter(.byColumn(column: "name"))
        XCTAssertEqual(viewModel.filterDraft.conditions.count, 1)
        XCTAssertEqual(viewModel.filterDraft.conditions.first?.column, "name")
        XCTAssertEqual(viewModel.filterDraft.conditions.first?.op, .equal)
        XCTAssertEqual(viewModel.filterDraft.conditions.first?.value, "")
        XCTAssertTrue(viewModel.filterDraft.isVisible)
        XCTAssertEqual(viewModel.filterFocusConditionID, viewModel.filterDraft.conditions.first?.id)
    }

    func testByValueAndExcludeApplyImmediately() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.applyQuickFilter(.byValue(column: "status", value: "draft"))
        await viewModel.waitForPendingWork()
        let byValueSQL = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(byValueSQL.contains("`status` = 'draft'"), byValueSQL)

        viewModel.applyQuickFilter(.excludeValue(column: "status", value: "deleted"))
        await viewModel.waitForPendingWork()
        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(sql.contains("`status` <> 'deleted'"), sql)
    }

    func testNullCellFilterUsesIsNull() async throws {
        harness.preferences.lazyLargeColumns = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([
            ("FROM `app_dev`.`users`", .single(columns: ["id", "name", "status"], rows: [["1", nil, "draft"]])),
        ])
        await viewModel.start()

        viewModel.filterByCellValue(rowID: viewModel.rows[0].id, column: "name", exclude: false)
        await viewModel.waitForPendingWork()
        let sql = await harness.mysql.executedSQL.last ?? ""
        XCTAssertTrue(sql.contains("`name` IS NULL"), sql)
    }

    // MARK: 持久化

    func testFilterPersistsAndRestoresForSameTable() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.addFilterCondition(column: "name", op: .contains, value: "张")
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()

        let tab2 = session.openTableData(database: "app_dev", table: "users", forceNew: true)
        let provider = FakeTableDataMetadataProvider(
            metadata: TableDataMetadata(
                columns: Self.columns,
                tableInfo: nil,
                isView: false,
                primaryKeyColumns: ["id"]
            ),
            rowCount: nil
        )
        let restored = TableDataViewModel(
            session: session,
            tab: tab2,
            metadataProvider: provider,
            preferences: harness.preferences,
            clock: harness.clock
        )
        XCTAssertEqual(restored.filterDraft.conditions.count, 1)
        XCTAssertEqual(restored.filterDraft.conditions.first?.value, "张")
        XCTAssertTrue(restored.filterDraft.isVisible)
        XCTAssertNotNil(restored.filter)
    }

    func testFilterNotRestoredWhenPreferenceDisabled() async throws {
        harness.preferences.rememberFilters = false
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.addFilterCondition(column: "name", op: .equal, value: "x")
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()

        let tab2 = session.openTableData(database: "app_dev", table: "users", forceNew: true)
        let provider = FakeTableDataMetadataProvider(
            metadata: TableDataMetadata(columns: Self.columns, tableInfo: nil, isView: false, primaryKeyColumns: ["id"]),
            rowCount: nil
        )
        let restored = TableDataViewModel(
            session: session,
            tab: tab2,
            metadataProvider: provider,
            preferences: harness.preferences,
            clock: harness.clock
        )
        XCTAssertTrue(restored.filterDraft.conditions.isEmpty)
        XCTAssertNil(restored.filter)
    }

    // MARK: 列显隐

    func testColumnVisibilityAppliesAndPersists() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.presentColumnFilter()
        XCTAssertTrue(viewModel.isColumnFilterPresented)
        viewModel.applyColumnVisibility(hidden: ["status"])
        viewModel.dismissColumnFilter()

        XCTAssertEqual(viewModel.hiddenColumns, ["status"])
        XCTAssertFalse(viewModel.isColumnFilterPresented)
        let layout = session.tableLayout(database: "app_dev", table: "users")
        XCTAssertEqual(layout?.hiddenColumns, ["status"])
    }

    func testColumnVisibilityCannotHideAllColumns() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([pageResponse(rowCount: 10)])
        await viewModel.start()

        viewModel.applyColumnVisibility(hidden: Set(Self.columns.map(\.name)))
        XCTAssertTrue(viewModel.hiddenColumns.isEmpty)
    }
}
