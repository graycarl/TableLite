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

    private func makeCoordinator() async throws -> (DataGridCoordinator, DataGridTableView) {
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

        let coordinator = DataGridCoordinator(viewModel: viewModel, preferences: harness.preferences, onQuickLook: { _ in })
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
        XCTAssertEqual(tableView.tableColumns[1].headerCell.attributedStringValue.string, "🔑 id")
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
}
