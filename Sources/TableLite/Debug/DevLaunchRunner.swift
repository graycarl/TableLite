#if DEBUG
import AppKit
import Foundation

/// 调试启动原语的执行器（`docs/tech-designs/15-testing.md` §9.2）。
///
/// 只在 Debug 构建存在（S50）。流程：等窗口 → 外观 → 窗口尺寸 → 显示条数（写偏好）→ 连接 →
/// 开表/标签 → 选格 → 造改动 → 场景 → 输出 ready JSON。任何一步失败都打印 `{"ready":false,…}`
/// 并退出，脚本据此报错，不靠 sleep 猜。
@MainActor
final class DevLaunchRunner {

    static func scheduleIfRequested(environment: AppEnvironment, options: DevLaunchOptions) {
        guard !options.isEmpty else { return }
        let runner = DevLaunchRunner(environment: environment, options: options)
        shared = runner
        runner.start()
    }

    /// 持有当前 runner：`start()` 里的 Task 只捕获 self，这里留一份保证整个调试周期内不被释放。
    private static var shared: DevLaunchRunner?

    private let environment: AppEnvironment
    private let options: DevLaunchOptions
    private var warnings: [String] = []

    private init(environment: AppEnvironment, options: DevLaunchOptions) {
        self.environment = environment
        self.options = options
    }

    private func start() {
        Task { @MainActor in
            let code = await self.run()
            fflush(stdout)
            // 成功时**不退出**：调试实例要留着给 agent 截图与交互。
            // 失败才退出，让脚本立刻拿到错误而不是等超时。
            if code != 0 { exit(code) }
        }
    }

    private func run() async -> Int32 {
        do {
            try await perform()
            try printReady()
            return 0
        } catch {
            DevLaunchOutput.printFailure(Self.describe(error))
            return 1
        }
    }

    // MARK: - 原语

    private func perform() async throws {
        try await waitForWindow(timeout: 15)

        if let appearance = options.appearance {
            apply(appearance)
        }
        if let size = options.windowSize {
            resizeWindow(to: size)
        }
        // 显示条数是偏好：必须在开表之前写，ViewModel 初始化时读（`15-testing.md` §9.2）。
        if let limit = options.rowLimit {
            environment.preferences.rowLimit = limit
        }

        // 没要求连接/开表时不要强连：第 1 个状态就是「连接列表空态」。
        let needsSession = options.connection != nil || options.openConnection != nil
            || options.openTable != nil || options.openTab != nil
            || options.selectCell != nil || !options.editCells.isEmpty
        if needsSession {
            let session = try await activeSession()
            if let table = options.openTable {
                try await openTable(table, in: session)
            }
            if let target = options.openTab {
                try await openTab(target, in: session)
            }
            if let cell = options.selectCell {
                try await select(cell, in: session)
            }
            for edit in options.editCells {
                try await applyEdit(edit, in: session)
            }
        }
        if let name = options.scenario {
            guard let scenario = DevScenarioRegistry.scenario(named: name) else {
                throw DevLaunchError.unknownScenario(name)
            }
            try await scenario.run(environment)
        }
    }

    private func waitForWindow(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = DevStateProbe.mainWindow() {
                // 坐标点击要求调试实例在最前面（§9.4）。这里只把自己的窗口抬到前面；
                // 按 PID 精确激活由 axctl（AXFrontmost）负责，同名双实例下不会激活错进程。
                NSApplication.shared.activate()
                window.makeKeyAndOrderFront(nil)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw StepError("等待主窗口超时（\(Int(timeout))s）")
    }

    private func apply(_ appearance: AppearanceMode) {
        environment.preferences.appearance = appearance
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    private func resizeWindow(to size: CGSize) {
        guard let window = DevStateProbe.mainWindow() else { return }
        window.setContentSize(size)
        window.center()
    }

    // MARK: 连接

    private func activeSession() async throws -> ConnectionSession {
        if let spec = options.connection {
            let environmentVariables = ProcessInfo.processInfo.environment
            let connection = Connection(
                name: "dev-connect",
                mysql: MySQLConfig(
                    host: spec.host,
                    port: spec.port,
                    user: environmentVariables["MYSQL_USER"] ?? "root",
                    database: spec.database,
                    keepAlive: false
                )
            )
            do {
                return try await environment.sessionManager.connect(
                    connection,
                    password: environmentVariables["MYSQL_PASSWORD"]
                )
            } catch {
                throw StepError("连接 \(spec.host):\(spec.port) 失败：\(error)")
            }
        }
        if let name = options.openConnection {
            let connections = try await environment.connections.allConnections()
            guard let connection = connections.first(where: {
                $0.name == name || $0.id.uuidString.lowercased() == name.lowercased()
            }) else {
                throw StepError("找不到连接「\(name)」（隔离 profile 里的连接见 `tl.sh reset` 的种子）")
            }
            let password = try? environment.credentials.password(for: connection.id, kind: .mysqlPassword)
            do {
                return try await environment.sessionManager.connect(connection, password: password)
            } catch {
                throw StepError("连接「\(name)」失败：\(error)")
            }
        }
        guard let session = environment.sessionManager.activeSession else {
            throw StepError("没有活动会话：用 --dev-connect 或 --dev-open-connection 指定连接")
        }
        return session
    }

    // MARK: 标签

    private func openTable(_ spec: DevLaunchOptions.TableSpec, in session: ConnectionSession) async throws {
        let database = try resolveDatabase(spec.database, in: session)
        let tab = session.openTableData(database: database, table: spec.table)
        var failure: String?
        guard let viewModel = await DevStateProbe.waitForLoaded(
            tab: tab,
            timeout: 30,
            onFailure: { failure = $0 }
        ) else {
            throw StepError("打开表 \(database).\(spec.table) 失败：\(failure ?? "30s 内未加载完成")")
        }
        // 标签现场（session.json）会带回自己的显示条数，把偏好压掉；照 `--bench-scroll` 的做法补一次。
        if let limit = options.rowLimit, viewModel.rowLimit != limit {
            var reloadFailure: String?
            viewModel.setRowLimit(limit)
            guard await DevStateProbe.waitForReload(
                tab: tab,
                timeout: 30,
                onFailure: { reloadFailure = $0 }
            ) != nil else {
                throw StepError("调整显示条数到 \(limit) 失败：\(reloadFailure ?? "30s 内未重载完成")")
            }
        }
    }

    private func openTab(_ target: DevLaunchOptions.TabTarget, in session: ConnectionSession) async throws {
        let tab: Tab
        switch target {
        case .query:
            tab = session.newQueryTab()
        case .history:
            tab = session.openHistoryTab()
        case .console:
            tab = session.openConsoleLogTab()
        case .structure:
            let (database, table) = try requireOpenTable(in: session)
            tab = session.openTableStructure(database: database, table: table)
        case .definition:
            let (database, table) = try requireOpenTable(in: session)
            tab = session.openObjectDefinition(database: database, object: table)
        }
        // 表数据标签的数据加载已由 --dev-open-table 等过；其余标签只需内容视图装配完成。
        if case .tableData = tab.kind { return }
        guard await DevStateProbe.waitForContent(tab: tab, timeout: 15) != nil else {
            throw StepError("标签「\(tab.title)」的内容视图 15s 内没有装配完成")
        }
    }

    private func requireOpenTable(in session: ConnectionSession) throws -> (String, String) {
        guard let spec = options.openTable else {
            throw StepError("--dev-open-tab structure/definition 需要同时给 --dev-open-table")
        }
        return (try resolveDatabase(spec.database, in: session), spec.table)
    }

    private func resolveDatabase(_ database: String?, in session: ConnectionSession) throws -> String {
        if let database, !database.isEmpty { return database }
        if let current = session.selectedDatabase, !current.isEmpty { return current }
        let configured = session.connection.mysql.database
        guard !configured.isEmpty else {
            throw StepError("无法确定库名：--dev-open-table 请写成 <db.table>")
        }
        return configured
    }

    // MARK: 选择 / 编辑

    private func activeTableViewModel(in session: ConnectionSession) throws -> TableDataViewModel {
        guard let tab = session.tabs.first(where: { $0.id == session.activeTabID }),
              let viewModel = tab.content as? TableDataViewModel else {
            throw StepError("当前标签不是表数据标签")
        }
        return viewModel
    }

    private func select(_ cell: DevLaunchOptions.CellRef, in session: ConnectionSession) async throws {
        let viewModel = try activeTableViewModel(in: session)
        guard viewModel.columns.contains(where: { $0.name == cell.column }) else {
            throw StepError("列「\(cell.column)」不存在（可用列见 ready JSON 的 state.columns）")
        }
        guard let row = viewModel.gridRows.first(where: { $0.rowIndexInPage == cell.row - 1 }) else {
            throw StepError("行号 \(cell.row) 超出范围（网格当前 \(viewModel.gridRows.count) 行）")
        }
        // `.loaded` 不代表 SwiftUI 已经把 DataGridTableView 建出来，轮询一下再点。
        let deadline = Date().addingTimeInterval(5)
        var tableView: NSTableView?
        while tableView == nil, Date() < deadline {
            tableView = DevStateProbe.findGridTableView()
            if tableView == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let tableView else { throw StepError("5s 内没有出现数据网格视图") }
        guard let index = viewModel.gridRows.firstIndex(where: { $0.id == row.id }),
              index < tableView.numberOfRows else {
            throw StepError("网格行索引越界（第 \(cell.row) 行 / 网格 \(tableView.numberOfRows) 行）")
        }
        tableView.scrollRowToVisible(index)
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        // 选区变化会经 delegate 回写；列焦点与字段栏在这里补一次（delegate 只能给首列）。
        viewModel.focusInspector(rowID: row.id, column: cell.column)
    }

    private func applyEdit(_ edit: DevLaunchOptions.CellEdit, in session: ConnectionSession) async throws {
        let viewModel = try activeTableViewModel(in: session)
        guard let row = viewModel.gridRows.first(where: { $0.rowIndexInPage == edit.row - 1 }) else {
            throw StepError("行号 \(edit.row) 超出范围（网格当前 \(viewModel.gridRows.count) 行）")
        }
        let before = viewModel.pendingCount
        await viewModel.applyInspectorEdit(rowID: row.id, column: edit.column, value: edit.value)
        if viewModel.pendingCount == before {
            // 产品在拒绝编辑时会弹轻提示（只读 / 无主键 / 行已删……），把它原样带出来。
            let reason = viewModel.copyNotice.map { "：\($0)" } ?? "（原因未知：只读 / 无主键 / 值未变化 / 截断值未加载）"
            throw StepError("--dev-edit-cell \(edit.row),\(edit.column) 没有产生改动\(reason)")
        }
    }

    // MARK: - ready

    private func printReady() throws {
        var payload: [String: Any] = [
            "ready": true,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "data_dir": environment.layout.rootDirectory.path,
            "defaults_suite": environment.defaultsSuiteName ?? "(standard)",
            "is_dev_profile": environment.isDevProfile
        ]
        if let window = DevStateProbe.mainWindow() {
            payload["window"] = [
                "id": window.windowNumber,
                "frame": [
                    "x": window.frame.origin.x,
                    "y": window.frame.origin.y,
                    "width": window.frame.width,
                    "height": window.frame.height
                ]
            ]
        }
        payload["state"] = stateSnapshot()
        payload["warnings"] = warnings

        let line = DevLaunchOutput.line(payload)
        if let readyFile = options.readyFile {
            do {
                try Data(line.utf8).write(to: readyFile, options: .atomic)
            } catch {
                // 写不出 ready 文件时脚本会一直等：必须失败退出，不能报 ready 让人白等。
                throw StepError("写入 ready 文件失败（\(readyFile.path)）：\(error)")
            }
        }
        print(line)
        fflush(stdout)
    }

    private func stateSnapshot() -> [String: Any] {
        var state: [String: Any] = [:]
        guard let session = environment.sessionManager.activeSession else { return state }
        state["connection"] = session.connection.name
        state["database"] = session.selectedDatabase ?? ""
        state["tabs"] = session.tabs.map(\.title)
        if let tab = session.tabs.first(where: { $0.id == session.activeTabID }) {
            state["tab"] = tab.title
            state["tab_kind"] = tab.kind.sessionKind.rawValue
            if let viewModel = tab.content as? TableDataViewModel {
                state["table"] = "\(viewModel.database).\(viewModel.table)"
                state["rows"] = viewModel.rows.count
                state["row_limit"] = viewModel.rowLimit
                state["pending"] = viewModel.pendingCount
                state["selected_rows"] = viewModel.selectedRowIDs.count
                state["focused_column"] = viewModel.focusedColumn ?? ""
                state["columns"] = viewModel.columns.map(\.name)
                state["load_state"] = String(describing: viewModel.loadState)
            }
        }
        return state
    }

    // MARK: - 错误

    private struct StepError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func describe(_ error: Error) -> String {
        if let step = error as? StepError { return step.description }
        if let dev = error as? DevLaunchError { return dev.description }
        return String(describing: error)
    }
}
#endif
