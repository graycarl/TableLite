import XCTest
@testable import TableLite

/// 工作区状态：按「连接 + 库 + 表」记住列宽 / 列显隐 / 过滤器。
@MainActor
final class WorkspaceStateStoreTests: XCTestCase {

    func testLayoutRoundTrip() {
        let store = InMemoryKeyValueStore()
        let workspace = WorkspaceStateStore(store: store)
        let connectionID = UUID()

        XCTAssertNil(workspace.layout(connectionID: connectionID, database: "app_dev", table: "users"))

        let layout = TableLayout(columnWidths: ["id": 80, "name": 240], hiddenColumns: ["payload"])
        workspace.setLayout(layout, connectionID: connectionID, database: "app_dev", table: "users")

        XCTAssertEqual(workspace.layout(connectionID: connectionID, database: "app_dev", table: "users"), layout)

        workspace.setLayout(nil, connectionID: connectionID, database: "app_dev", table: "users")
        XCTAssertNil(workspace.layout(connectionID: connectionID, database: "app_dev", table: "users"))
    }

    func testLayoutPersistsAcrossInstances() {
        let store = InMemoryKeyValueStore()
        let connectionID = UUID()
        let layout = TableLayout(columnWidths: ["id": 100], hiddenColumns: [])

        WorkspaceStateStore(store: store)
            .setLayout(layout, connectionID: connectionID, database: "app_dev", table: "users")

        let reloaded = WorkspaceStateStore(store: store)
        XCTAssertEqual(reloaded.layout(connectionID: connectionID, database: "app_dev", table: "users"), layout)
    }

    func testEmptyLayoutIsNotStored() {
        let workspace = WorkspaceStateStore(store: InMemoryKeyValueStore())
        let connectionID = UUID()
        workspace.setLayout(TableLayout(), connectionID: connectionID, database: "app_dev", table: "users")
        XCTAssertNil(workspace.layout(connectionID: connectionID, database: "app_dev", table: "users"))
    }

    func testFilterRoundTrip() {
        let workspace = WorkspaceStateStore(store: InMemoryKeyValueStore())
        let connectionID = UUID()
        let filter = FilterState(rawWhere: "id > 10", isRawMode: true, isVisible: true)

        workspace.setFilter(filter, connectionID: connectionID, database: "app_dev", table: "users")
        XCTAssertEqual(workspace.filter(connectionID: connectionID, database: "app_dev", table: "users"), filter)

        workspace.setFilter(nil, connectionID: connectionID, database: "app_dev", table: "users")
        XCTAssertNil(workspace.filter(connectionID: connectionID, database: "app_dev", table: "users"))
    }

    func testEmptyFilterIsNotStored() {
        let workspace = WorkspaceStateStore(store: InMemoryKeyValueStore())
        let connectionID = UUID()
        workspace.setFilter(FilterState(), connectionID: connectionID, database: "app_dev", table: "users")
        XCTAssertNil(workspace.filter(connectionID: connectionID, database: "app_dev", table: "users"))
    }

    func testRemoveAllForConnectionOnly() {
        let workspace = WorkspaceStateStore(store: InMemoryKeyValueStore())
        let first = UUID()
        let second = UUID()
        let layout = TableLayout(columnWidths: ["id": 80], hiddenColumns: [])

        workspace.setLayout(layout, connectionID: first, database: "app_dev", table: "users")
        workspace.setLayout(layout, connectionID: second, database: "app_dev", table: "users")

        workspace.removeAll(connectionID: first)
        XCTAssertNil(workspace.layout(connectionID: first, database: "app_dev", table: "users"))
        XCTAssertEqual(workspace.layout(connectionID: second, database: "app_dev", table: "users"), layout)
    }

    func testSameTableNameInDifferentDatabasesAreIndependent() {
        let workspace = WorkspaceStateStore(store: InMemoryKeyValueStore())
        let connectionID = UUID()
        workspace.setLayout(
            TableLayout(columnWidths: ["id": 80]),
            connectionID: connectionID, database: "app_dev", table: "users"
        )
        XCTAssertNil(workspace.layout(connectionID: connectionID, database: "app_staging", table: "users"))
    }

    func testWindowAutosaveName() {
        XCTAssertEqual(WorkspaceStateStore.windowFrameAutosaveName, "TableLite.MainWindow")
    }
}
