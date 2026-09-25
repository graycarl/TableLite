import XCTest
import AppKit
@testable import TableLite

/// AppKit 网格桥接的冒烟测试：列构造、行数、cell view 复用、右键菜单。
///
/// 不依赖窗口，直接驱动 `DataGridCoordinator`。
@MainActor
final class DataGridBridgeTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    private func makeCoordinator(
        onQuickLook: @escaping (QuickLookContent) -> Void = { _ in }
    ) async throws -> (DataGridCoordinator, DataGridTableView) {
        harness.preferences.lazyLargeColumns = false
        let session = try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
        let tab = session.openTableData(database: "app_dev", table: "users")
        let columns = [
            TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey),
            TestSupport.column("name", type: .varString),
        ]
        let metadata = TableDataMetadata(
            columns: columns,
            tableInfo: TableInfo(database: "app_dev", name: "users", rowCountEstimate: 2),
            isView: false,
            primaryKeyColumns: ["id"]
        )
        let provider = FakeTableDataMetadataProvider(metadata: metadata, rowCount: RowCountEstimate(approximate: 2))
        let viewModel = TableDataViewModel(
            session: session,
            tab: tab,
            metadataProvider: provider,
            preferences: harness.preferences,
            clock: harness.clock
        )
        await harness.mysql.setResponses([
            ("FROM `app_dev`.`users`", .single(
                columns: ["id", "name"],
                rows: [["1", "张三"], ["2", "李四"]]
            )),
        ])
        await viewModel.start()

        let coordinator = DataGridCoordinator(viewModel: viewModel, preferences: harness.preferences, onQuickLook: onQuickLook)
        let tableView = DataGridTableView()
        coordinator.tableView = tableView
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.rebuildColumns()
        return (coordinator, tableView)
    }

    func testCoordinatorBuildsRowNumberAndDataColumns() async throws {
        let (coordinator, tableView) = try await makeCoordinator()

        XCTAssertEqual(tableView.numberOfColumns, 3) // 行号 + id + name
        XCTAssertEqual(tableView.tableColumns.first?.identifier, DataGridCoordinator.rowNumberIdentifier)
        XCTAssertEqual(coordinator.numberOfRows(in: tableView), 2)
        // 主键表头：SF Symbol 钥匙图标附件（`07-data-grid.md` §4），附件在 .string 里是 U+FFFC 占位符。
        let header = tableView.tableColumns[1].headerCell.attributedStringValue
        XCTAssertEqual(header.string, "\u{FFFC} id")
        XCTAssertTrue(header.containsAttachments(in: NSRange(location: 0, length: header.length)))
    }

    func testCoordinatorProvidesCellViews() async throws {
        let (coordinator, tableView) = try await makeCoordinator()

        let numberCell = coordinator.tableView(tableView, viewFor: tableView.tableColumns[0], row: 0)
        XCTAssertEqual((numberCell as? NSTableCellView)?.textField?.stringValue, "1")

        let nameCell = coordinator.tableView(tableView, viewFor: tableView.tableColumns[2], row: 1)
        XCTAssertTrue(nameCell is GridCellView)
    }

    func testColumnMenuReflectsVisibility() async throws {
        let (coordinator, _) = try await makeCoordinator()
        // 行号列（index 0）不提供筛选项。
        let menu = coordinator.makeColumnMenu(columnIndex: 0)
        // 第一项是标题，其后每列一项。
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.items[1].state, .on)
    }

    // MARK: 键盘 / 中键（`specs/02-workspace.md` §9）

    func testCommandArrowMovesFocusToFirstAndLastRow() async throws {
        let (coordinator, _) = try await makeCoordinator()
        let viewModel = coordinator.viewModel
        viewModel.updateSelection(
            rowIDs: [viewModel.rows[1].id],
            focusedRowID: viewModel.rows[1].id,
            focusedColumn: "name"
        )
        coordinator.sync()

        coordinator.moveFocusToLastRow()
        XCTAssertEqual(viewModel.focusedRowID, viewModel.rows.last?.id)
        XCTAssertEqual(viewModel.inspectorRow?.id, viewModel.rows.last?.id)

        coordinator.moveFocusToFirstRow()
        XCTAssertEqual(viewModel.focusedRowID, viewModel.rows.first?.id)
        XCTAssertEqual(viewModel.inspectorRow?.id, viewModel.rows.first?.id)
    }

    func testReturnOpensInspectorAndFocusesField() async throws {
        let (coordinator, _) = try await makeCoordinator()
        let viewModel = coordinator.viewModel
        viewModel.updateSelection(
            rowIDs: [viewModel.rows[0].id],
            focusedRowID: viewModel.rows[0].id,
            focusedColumn: "name"
        )
        coordinator.sync()
        let tokenBefore = viewModel.focusRequestToken

        coordinator.activateFocusedCell()

        XCTAssertEqual(viewModel.focusedColumn, "name")
        XCTAssertEqual(viewModel.focusRequestColumn, "name")
        XCTAssertGreaterThan(viewModel.focusRequestToken, tokenBefore)
    }

    func testMiddleButtonQuickLookPresentsAndSelects() async throws {
        var presented: QuickLookContent?
        let (coordinator, _) = try await makeCoordinator(onQuickLook: { presented = $0 })
        let viewModel = coordinator.viewModel

        // 第 2 列是 name（第 0 列是行号）。
        coordinator.quickLook(row: 1, column: 2)

        XCTAssertEqual(presented?.columnName, "name")
        XCTAssertEqual(viewModel.focusedRowID, viewModel.rows[1].id)
        XCTAssertEqual(viewModel.focusedColumn, "name")
    }
}

/// 外键 `↗` 的渲染与点击命中（`specs/03-data-browsing.md` §10）。
@MainActor
final class DataGridForeignKeyTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    private func makeCoordinator() async throws -> (DataGridCoordinator, DataGridTableView) {
        harness.preferences.lazyLargeColumns = false
        let session = try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
        let tab = session.openTableData(database: "app_dev", table: "orders")
        let columns = [
            TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey),
            TestSupport.column("user_id", type: .long),
        ]
        let foreignKey = ForeignKeyInfo(
            name: "fk_orders_user",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"]
        )
        let metadata = TableDataMetadata(
            columns: columns,
            tableInfo: TableInfo(database: "app_dev", name: "orders", rowCountEstimate: 2),
            isView: false,
            primaryKeyColumns: ["id"],
            foreignKeyColumns: ["user_id"],
            foreignKeys: [foreignKey]
        )
        let provider = FakeTableDataMetadataProvider(metadata: metadata, rowCount: RowCountEstimate(approximate: 2))
        let viewModel = TableDataViewModel(
            session: session,
            tab: tab,
            metadataProvider: provider,
            preferences: harness.preferences,
            clock: harness.clock
        )
        await harness.mysql.setResponses([
            ("FROM `app_dev`.`orders`", .single(
                columns: ["id", "user_id"],
                rows: [["1", "42"], ["2", nil]]
            )),
        ])
        await viewModel.start()

        let coordinator = DataGridCoordinator(viewModel: viewModel, preferences: harness.preferences, onQuickLook: { _ in })
        let tableView = DataGridTableView()
        coordinator.tableView = tableView
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.rebuildColumns()
        return (coordinator, tableView)
    }

    func testForeignKeyCellRendersArrowOnlyWhenValueIsNotNull() async throws {
        let (coordinator, tableView) = try await makeCoordinator()
        // 第 2 列是 user_id（第 0 列是行号）。
        let userIDColumn = tableView.tableColumns[2]

        let nonNull = coordinator.tableView(tableView, viewFor: userIDColumn, row: 0) as? GridCellView
        XCTAssertEqual(nonNull?.renderedText, "42")
        XCTAssertEqual(nonNull?.isForeignKeyIndicatorVisible, true)

        let null = coordinator.tableView(tableView, viewFor: userIDColumn, row: 1) as? GridCellView
        XCTAssertEqual(null?.renderedText, "NULL")
        XCTAssertEqual(null?.isForeignKeyIndicatorVisible, false)
    }

    func testForeignKeyArrowHitOnlyOnTrailingZone() async throws {
        let (coordinator, tableView) = try await makeCoordinator()
        let frame = tableView.frameOfCell(atColumn: 2, row: 0)
        let trailing = NSPoint(x: frame.maxX - 5, y: frame.midY)
        let leading = NSPoint(x: frame.minX + 2, y: frame.midY)

        XCTAssertTrue(coordinator.isForeignKeyArrowHit(row: 0, column: 2, point: trailing))
        XCTAssertFalse(coordinator.isForeignKeyArrowHit(row: 0, column: 2, point: leading))
        // NULL 值不命中。
        XCTAssertFalse(coordinator.isForeignKeyArrowHit(row: 1, column: 2, point: trailing))
    }
}
