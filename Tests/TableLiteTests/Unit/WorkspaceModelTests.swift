import XCTest
@testable import TableLite

/// 工作区纯逻辑：对象树过滤 / 分组、标签切换、状态栏文案。
///
/// 这些逻辑抽成纯函数是为了可单测（`AGENTS.md`「代码约定」）。
final class WorkspaceModelTests: XCTestCase {

    // MARK: - 对象树过滤

    func testFilterIsCaseInsensitiveSubstring() {
        let objects = [
            TableInfo(database: "db", name: "users", kind: .table),
            TableInfo(database: "db", name: "Orders", kind: .table),
            TableInfo(database: "db", name: "v_active_users", kind: .view),
        ]
        XCTAssertEqual(ObjectTreeModel.filtered(objects, query: "USER").map(\.name), ["users", "v_active_users"])
        XCTAssertEqual(ObjectTreeModel.filtered(objects, query: "ord").map(\.name), ["Orders"])
    }

    func testFilterTrimsWhitespaceAndReturnsAllWhenEmpty() {
        let objects = [
            TableInfo(database: "db", name: "users", kind: .table),
            TableInfo(database: "db", name: "orders", kind: .table),
        ]
        XCTAssertEqual(ObjectTreeModel.filtered(objects, query: "   ").count, 2)
        XCTAssertEqual(ObjectTreeModel.filtered(objects, query: " users ").map(\.name), ["users"])
    }

    // MARK: - 对象树分组

    func testGroupSplitsTablesAndViewsAndCounts() {
        let objects = [
            TableInfo(database: "db", name: "users", kind: .table),
            TableInfo(database: "db", name: "orders", kind: .table),
            TableInfo(database: "db", name: "v_users", kind: .view),
        ]
        let groups = ObjectTreeModel.group(objects)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].group, .table)
        XCTAssertEqual(groups[0].items.map(\.name), ["users", "orders"])
        XCTAssertEqual(groups[0].title, "表 (2)")
        XCTAssertFalse(groups[0].isFiltering)

        XCTAssertEqual(groups[1].group, .view)
        XCTAssertEqual(groups[1].items.map(\.name), ["v_users"])
        XCTAssertEqual(groups[1].title, "视图 (1)")
    }

    func testGroupCountUsesMatchesWhenFiltering() {
        let objects = [
            TableInfo(database: "db", name: "users", kind: .table),
            TableInfo(database: "db", name: "orders", kind: .table),
            TableInfo(database: "db", name: "v_users", kind: .view),
        ]
        let groups = ObjectTreeModel.group(objects, query: "users")

        XCTAssertEqual(groups[0].title, "表 (1)")
        XCTAssertEqual(groups[0].items.map(\.name), ["users"])
        XCTAssertTrue(groups[0].isFiltering)

        XCTAssertEqual(groups[1].title, "视图 (1)")
        XCTAssertEqual(groups[1].items.map(\.name), ["v_users"])
    }

    func testGroupAppliesDisplayLimitAndFlagsTruncation() {
        let objects = (0..<10).map { TableInfo(database: "db", name: "t\($0)", kind: .table) }
        let groups = ObjectTreeModel.group(objects, limit: 4)

        XCTAssertEqual(groups[0].items.count, 4)
        XCTAssertEqual(groups[0].total, 10)
        XCTAssertTrue(groups[0].isTruncated)
        // 计数仍显示真实总数。
        XCTAssertEqual(groups[0].title, "表 (10)")

        XCTAssertFalse(groups[1].isTruncated)
        XCTAssertTrue(groups[1].isEmpty)
        XCTAssertEqual(groups[1].title, "视图 (0)")
    }

    // MARK: - 标签切换

    func testNextAndPreviousWrapAround() {
        XCTAssertEqual(TabNavigator.nextIndex(current: 0, count: 3), 1)
        XCTAssertEqual(TabNavigator.nextIndex(current: 2, count: 3), 0)
        XCTAssertEqual(TabNavigator.previousIndex(current: 0, count: 3), 2)
        XCTAssertEqual(TabNavigator.previousIndex(current: 1, count: 3), 0)
    }

    func testNavigationWithoutTabsIsNil() {
        XCTAssertNil(TabNavigator.nextIndex(current: 0, count: 0))
        XCTAssertNil(TabNavigator.previousIndex(current: 0, count: 0))
    }

    func testShortcutIndexIsOneBasedAndBounded() {
        XCTAssertEqual(TabNavigator.index(forShortcut: 1, count: 3), 0)
        XCTAssertEqual(TabNavigator.index(forShortcut: 3, count: 3), 2)
        XCTAssertNil(TabNavigator.index(forShortcut: 4, count: 3))
        XCTAssertNil(TabNavigator.index(forShortcut: 0, count: 3))
        XCTAssertNil(TabNavigator.index(forShortcut: 10, count: 20))
    }

    // MARK: - 状态栏文案

    func testConnectionLineConnected() {
        let connection = Connection(name: "本地开发", mysql: MySQLConfig(database: "app_dev"))
        let info = ServerInfo(version: "8.0.36", charset: "utf8mb4", connectionCharset: "utf8mb4")
        let line = WorkspaceStatusText.connectionLine(
            connection: connection,
            state: .connected,
            database: "app_dev",
            serverInfo: info,
            isReadOnly: false
        )
        XCTAssertEqual(line, "本地开发 · app_dev · MySQL 8.0.36 · utf8mb4")
    }

    func testConnectionLineReadOnlyAppendsMarker() {
        let connection = Connection(name: "生产", isReadOnly: true)
        let line = WorkspaceStatusText.connectionLine(
            connection: connection,
            state: .disconnected,
            database: nil,
            serverInfo: nil,
            isReadOnly: true
        )
        XCTAssertEqual(line, "生产 · 未连接 · 只读")
    }

    func testTabSummaryForConsoleLogUsesCount() {
        XCTAssertEqual(
            WorkspaceStatusText.tabSummary(for: .consoleLog, page: nil, consoleLogCount: 7),
            "已记录 7 条语句"
        )
    }
}
