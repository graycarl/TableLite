import XCTest
@testable import TableLite

/// 标签模型：去重规则与 `session.json` 往返。
@MainActor
final class TabModelTests: XCTestCase {

    // MARK: 去重

    func testQueryTabsAreNeverReused() {
        let kind = TabKind.query(draftID: UUID())
        XCTAssertFalse(kind.isReusable)
        XCTAssertNil(TabKind.existingIndex(for: kind, in: [kind]))
    }

    func testTableDataDedupBySchemaAndName() {
        let first = TabKind.tableData(database: "db", table: "t")
        let same = TabKind.tableData(database: "db", table: "t")
        let otherDatabase = TabKind.tableData(database: "other", table: "t")
        let otherTable = TabKind.tableData(database: "db", table: "u")

        XCTAssertTrue(first.matches(same))
        XCTAssertFalse(first.matches(otherDatabase))
        XCTAssertFalse(first.matches(otherTable))
        XCTAssertEqual(TabKind.existingIndex(for: first, in: [otherTable, same]), 1)
    }

    func testObjectDefinitionAndStructureAreDistinct() {
        let structure = TabKind.tableStructure(database: "db", table: "v")
        let definition = TabKind.objectDefinition(database: "db", object: "v")
        XCTAssertFalse(structure.matches(definition))
    }

    func testSingletonTabsMatchOnlyThemselves() {
        XCTAssertTrue(TabKind.history.matches(.history))
        XCTAssertTrue(TabKind.consoleLog.matches(.consoleLog))
        XCTAssertFalse(TabKind.history.matches(.consoleLog))
    }

    // MARK: 标题

    func testQueryTitleUsesNumberAndCustomTitle() {
        let tab = Tab(kind: .query(draftID: UUID()), queryNumber: 3)
        XCTAssertEqual(tab.title, "查询 3")
        tab.customTitle = "排查订单"
        XCTAssertEqual(tab.title, "排查订单")
    }

    func testStructureTitle() {
        let tab = Tab(kind: .tableStructure(database: "db", table: "users"))
        XCTAssertEqual(tab.title, "users · 结构")
    }

    // MARK: 往返

    func testSnapshotRoundTripPreservesTableDataState() throws {
        let tab = Tab(kind: .tableData(database: "db", table: "users"))
        tab.page = PageState(pageIndex: 2, pageSize: 300)
        tab.sort = [SortOrder(column: "id", direction: .descending)]
        tab.hiddenColumns = ["payload"]
        tab.filter = FilterState(rawWhere: "id > 1", isRawMode: true, isVisible: true)
        tab.scrollRow = 42
        tab.focusedColumn = "name"

        let state = tab.snapshot()
        let restored = try XCTUnwrap(Tab(state: state))

        XCTAssertEqual(restored.id, tab.id)
        XCTAssertEqual(restored.kind, tab.kind)
        XCTAssertEqual(restored.page, tab.page)
        XCTAssertEqual(restored.sort, tab.sort)
        XCTAssertEqual(restored.hiddenColumns, tab.hiddenColumns)
        XCTAssertEqual(restored.filter, tab.filter)
        XCTAssertEqual(restored.scrollRow, 42)
        XCTAssertEqual(restored.focusedColumn, "name")
        XCTAssertEqual(restored.snapshot(), state)
    }

    func testSnapshotRoundTripPreservesQueryDraftAndStale() throws {
        let draftID = UUID()
        let tab = Tab(kind: .query(draftID: draftID), queryNumber: 1)
        tab.customTitle = "查询草稿"

        let restored = try XCTUnwrap(Tab(state: tab.snapshot()))
        XCTAssertEqual(restored.kind, .query(draftID: draftID))
        XCTAssertEqual(restored.title, "查询草稿")
    }

    func testRestoredStructureTabIsMarkedStale() throws {
        let tab = Tab(kind: .tableStructure(database: "db", table: "users"))
        let state = tab.snapshot()
        let restored = try XCTUnwrap(Tab(state: state))
        XCTAssertTrue(restored.isStale)
    }

    func testInvalidSnapshotReturnsNil() {
        var state = SessionTabState(kind: .tableData, database: nil, objectName: nil)
        XCTAssertNil(Tab(state: state))
        state = SessionTabState(kind: .query, queryDraftID: nil)
        XCTAssertNil(Tab(state: state))
    }
}
