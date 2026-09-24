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

    /// 状态栏把只读段单独渲染，主体与只读段拼接后必须与 `connectionLine` 一致
    /// （`specs/09-readonly-mode.md` §3）。
    func testConnectionLinePartsSplitsReadOnlyMarker() {
        let connection = Connection(name: "生产", isReadOnly: true)
        let info = ServerInfo(version: "8.0.36", charset: "utf8mb4", connectionCharset: "utf8mb4")
        let parts = WorkspaceStatusText.connectionLineParts(
            connection: connection,
            state: .connected,
            database: "app_prod",
            serverInfo: info,
            isReadOnly: true
        )
        XCTAssertEqual(parts.body, "生产 · app_prod · MySQL 8.0.36 · utf8mb4")
        XCTAssertEqual(parts.readOnlyMarker, "· 只读")
        XCTAssertEqual(
            "\(parts.body) \(parts.readOnlyMarker ?? "")",
            "生产 · app_prod · MySQL 8.0.36 · utf8mb4 · 只读"
        )
    }

    func testConnectionLinePartsOmitsReadOnlyMarkerWhenWritable() {
        let connection = Connection(name: "本地开发")
        let parts = WorkspaceStatusText.connectionLineParts(
            connection: connection,
            state: .disconnected,
            database: nil,
            serverInfo: nil,
            isReadOnly: false
        )
        XCTAssertEqual(parts.body, "本地开发 · 未连接")
        XCTAssertNil(parts.readOnlyMarker)
    }

    /// 连接中应为转圈，其余状态为圆点（`specs/01-connections.md` §4），
    /// 工具栏下拉 / 状态栏与连接列表含义一致。
    func testConnectingStateUsesSpinnerIndicator() {
        XCTAssertEqual(
            SessionConnectionState.connecting(.mysql).indicatorStyle,
            .spinner
        )
        XCTAssertEqual(SessionConnectionState.connected.indicatorStyle, .dot)
        XCTAssertEqual(SessionConnectionState.disconnected.indicatorStyle, .dot)
        XCTAssertEqual(SessionConnectionState.recycled.indicatorStyle, .dot)
    }

    func testConsoleLogCountLabelKeepsCountAndRetention() {
        XCTAssertEqual(
            WorkspaceStatusText.consoleLogCountLabel(count: 12, capacity: 5000),
            "12 条 · 保留最近 5000 条"
        )
    }

    func testTunnelDetailLine() {
        XCTAssertEqual(
            WorkspaceStatusText.tunnelDetailLine(host: "127.0.0.1", port: 53142),
            "本地转发端口 127.0.0.1:53142"
        )
    }

    func testConnectionLineShowsTunnelDisconnectedForClosedTunnel() {
        let connection = Connection(name: "生产")
        let failure = ConnectFailure(step: .sshTunnel, reason: .ssh(.tunnelClosed(stderrTail: "")))
        let line = WorkspaceStatusText.connectionLine(
            connection: connection,
            state: .failed(failure),
            database: nil,
            serverInfo: nil,
            isReadOnly: false
        )
        XCTAssertEqual(line, "生产 · SSH 隧道已断开")
    }

    func testConnectionTooltipListsTunnelAndHint() {
        let parts = WorkspaceStatusText.ConnectionLineParts(body: "生产 · app_prod", readOnlyMarker: "· 只读")
        XCTAssertEqual(
            WorkspaceStatusText.connectionTooltip(
                lineParts: parts,
                tunnelLine: "本地转发端口 127.0.0.1:53142"
            ),
            "生产 · app_prod · 只读\n本地转发端口 127.0.0.1:53142\n点击切换连接"
        )
        XCTAssertEqual(
            WorkspaceStatusText.connectionTooltip(lineParts: parts, tunnelLine: nil),
            "生产 · app_prod · 只读\n点击切换连接"
        )
    }

    // MARK: - 加载耗时与查询摘要（`specs/12-feedback.md` §6）

    func testTableDataSummaryHidesFastQueryDuration() {
        let base = "显示 300 行 / 约 12,480 行"
        XCTAssertEqual(
            WorkspaceStatusText.tableDataSummary(base: base, elapsedMilliseconds: nil),
            base
        )
        // 恰好 1 秒不显示。
        XCTAssertEqual(
            WorkspaceStatusText.tableDataSummary(base: base, elapsedMilliseconds: 1_000),
            base
        )
    }

    func testTableDataSummaryShowsSlowQueryDuration() {
        let base = "显示 300 行 / 约 12,480 行"
        XCTAssertEqual(
            WorkspaceStatusText.tableDataSummary(base: base, elapsedMilliseconds: 1_001),
            "\(base) · 1001 ms"
        )
    }

    func testCancelButtonAppearsOnlyAfterTenSeconds() {
        XCTAssertFalse(WorkspaceStatusText.showsCancelButton(elapsedMilliseconds: 10_000))
        XCTAssertFalse(WorkspaceStatusText.showsCancelButton(elapsedMilliseconds: 9_999))
        XCTAssertTrue(WorkspaceStatusText.showsCancelButton(elapsedMilliseconds: 10_001))
    }

    func testQuerySummaryFormatAndNoExecutionFallback() {
        XCTAssertNil(
            WorkspaceStatusText.querySummary(
                executedStatementCount: 0,
                elapsedMilliseconds: 0,
                totalReturnedRows: 0
            )
        )
        XCTAssertEqual(
            WorkspaceStatusText.querySummary(
                executedStatementCount: 3,
                elapsedMilliseconds: 42,
                totalReturnedRows: 1_204
            ),
            "已执行 3 条语句 · 耗时 42 ms · 返回 1,204 行"
        )
        // 0 行 / 0 ms 时省略对应片段，与编辑器内部状态栏一致。
        XCTAssertEqual(
            WorkspaceStatusText.querySummary(
                executedStatementCount: 1,
                elapsedMilliseconds: 0,
                totalReturnedRows: 0
            ),
            "已执行 1 条语句"
        )
    }
}
