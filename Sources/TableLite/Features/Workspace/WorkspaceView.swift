import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 工作区

/// 单窗口四层布局：工具栏 → 2pt 连接颜色带 → 主体区 → 状态栏。
///
/// 主体区横向三块：左侧栏（可拖宽、可隐藏）、标签内容区、右侧字段栏（由表数据标签自己渲染）。
/// 见 `specs/02-workspace.md` §1、`docs/tech-designs/06-ui-layer.md` §2。
///
/// 状态归属：所有状态都在 `AppEnvironment` / `SessionManager` / `ConnectionSession` 里，
/// 本视图只读状态、只发意图。
struct WorkspaceView: View {

    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        // 轻提示遮罩由根视图统一叠加（见 `TableLiteApp`），这里不再重复。
        WorkspaceContainer(sessionManager: env.sessionManager)
    }
}

// MARK: - 容器（观察 SessionManager）

private struct WorkspaceContainer: View {

    @ObservedObject var sessionManager: SessionManager
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if let session = sessionManager.activeSession {
            WorkspaceSessionView(session: session,
                                  preferences: env.preferences,
                                  sessionManager: sessionManager)
                .id(session.id)
        } else {
            WorkspaceNoSessionView(sessionManager: sessionManager,
                                   connections: env.connections)
        }
    }
}

// MARK: - 单个连接的工作区

private struct WorkspaceSessionView: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessionManager: SessionManager
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var toasts: ToastCenter

    @StateObject private var objectTree = ObjectTreeModel()

    /// 工作区级的变更操作面板：菜单与工具栏共用同一条路径，
    /// 避免在 `WorkspaceToolbar` 里再放一份 sheet / alert（见任务说明与 `docs/06-ui-layer.md` §5）。
    @State private var pendingPreview: WorkspacePreviewPresentation?
    @State private var commitFailure: CommitFailurePresentation?
    @State private var commitFailureModel: TableDataViewModel?
    @State private var confirmDialog: WorkspaceConfirmDialog?
    @State private var showsSwitchDatabase = false
    @State private var quickLookController = QuickLookPanelController()

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(session: session,
                             sessionManager: sessionManager,
                             preferences: preferences,
                             tableDataCommands: tableDataCommands)

            WorkspaceColorBand(color: WorkspaceColorMapping.color(for: session.connection.color))

            Divider()

            HStack(spacing: 0) {
                if preferences.sidebarVisible {
                    SidebarView(session: session, objectTree: objectTree, preferences: preferences)
                        .frame(width: CGFloat(preferences.sidebarWidth))

                    SplitHandle(width: Binding(get: { preferences.sidebarWidth },
                                               set: { preferences.sidebarWidth = $0 }),
                                range: 180...480,
                                onCommit: { preferences.sidebarWidth = $0 })
                }

                VStack(spacing: 0) {
                    TabBarView(session: session, environment: env)
                    Divider()
                    TabContentView(session: session)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusBarView(session: session)
        }
        .frame(minWidth: 760, minHeight: 480)
        // 菜单动作从这里上报；查询标签的文件动作也走同一条路径。
        .focusedSceneValue(\.tableLiteWorkspaceActions, workspaceActions)
        .onAppear {
            syncObjectTree()
            announceReadOnlyIfNeeded()
        }
        .onChange(of: session.objects) { _, _ in syncObjectTree() }
        .onChange(of: session.selectedDatabase) { _, _ in syncObjectTree() }
        .onChange(of: session.isReadOnly) { _, newValue in
            if newValue { announceReadOnly() }
        }
        .sheet(item: $pendingPreview) { presentation in
            PendingPreviewSheet(
                statements: presentation.statements,
                onOpenInQuery: { statements in
                    let sql = statements.map(\.text).joined(separator: "\n\n")
                    session.newQueryTab(initialSQL: sql)
                },
                onDiscard: { requestDiscard(presentation.model) },
                onSubmit: { commit(presentation.model) }
            )
        }
        .sheet(item: $commitFailure) { presentation in
            CommitErrorSheet(
                failure: presentation.failure,
                onDiscardAll: {
                    guard let model = commitFailureModel else { return }
                    Task { await model.discardAll() }
                },
                onClose: {}
            )
        }
        .sheet(isPresented: $showsSwitchDatabase) {
            WorkspaceDatabaseSwitcherSheet(session: session, isPresented: $showsSwitchDatabase)
        }
        .confirmationDialog(confirmDialogTitle,
                            isPresented: confirmDialogPresented,
                            titleVisibility: .visible,
                            presenting: confirmDialog) { dialog in
            switch dialog {
            case .close(let tab):
                Button("提交并关闭") { commitAndClose(tab) }
                Button("放弃并关闭", role: .destructive) { discardAndClose(tab) }
                Button("取消", role: .cancel) { confirmDialog = nil }
            case .discard(let model):
                Button("放弃修改", role: .destructive) {
                    Task { await model.discardAll() }
                    confirmDialog = nil
                }
                Button("取消", role: .cancel) { confirmDialog = nil }
            }
        } message: { dialog in
            switch dialog {
            case .close:
                Text("提交会真的写入数据库；放弃会丢弃这个标签里的全部未保存改动。")
            case .discard(let model):
                Text("将丢弃 \(model.pendingStats.total) 处修改：\(model.pendingStats.summary)。此操作不可撤销。")
            }
        }
    }

    // MARK: 菜单动作装配

    /// 菜单动作是**惰性**的：闭包在触发时才去 `session.activeTab` 取当前 ViewModel。
    ///
    /// 因为标签的 ViewModel 在内容视图 `onAppear` 才回填到 `Tab`，早于这里第一次
    /// 组装 actions；如果提前把 ViewModel 取出来，菜单会拿到过期的 `nil`。
    /// 按标签种类决定哪些动作可用（种类来自 `@Published` 的标签集合，总是最新）。
    private var workspaceActions: WorkspaceCommandActions {
        var actions = WorkspaceCommandActions()
        actions.newQuery = { session.newQueryTab() }
        actions.closeTab = { closeActiveTab() }
        actions.previousTab = { selectRelative(offset: -1) }
        actions.nextTab = { selectRelative(offset: 1) }
        actions.refresh = { refreshActiveTab() }
        actions.switchDatabase = { showsSwitchDatabase = true }
        actions.toggleSidebar = { preferences.sidebarVisible.toggle() }
        actions.toggleConsoleLog = { session.openConsoleLogTab() }

        if let tab = session.activeTab {
            switch tab.kind {
            case .tableData:
                // 字段栏只在表数据标签里可用（specs/02-workspace.md §2）。
                actions.toggleRowInspector = { preferences.showRowInspector.toggle() }
                // 只读连接上「提交」始终禁用（specs/09-readonly-mode.md §4）。
                if !session.isReadOnly {
                    actions.commit = {
                        guard let model = tab.tableData as? TableDataViewModel else { return }
                        commit(model)
                    }
                }
                actions.previewSQL = {
                    guard let model = tab.tableData as? TableDataViewModel else { return }
                    presentPreview(model)
                }
                actions.discard = {
                    guard let model = tab.tableData as? TableDataViewModel else { return }
                    requestDiscard(model)
                }
                actions.insertRow = { _ = (tab.tableData as? TableDataViewModel)?.insertRow() }
                actions.duplicateRow = {
                    guard let model = tab.tableData as? TableDataViewModel else { return }
                    duplicateRows(in: model)
                }
                actions.deleteRow = {
                    guard let model = tab.tableData as? TableDataViewModel else { return }
                    deleteRows(in: model)
                }
                actions.quickLook = {
                    guard let model = tab.tableData as? TableDataViewModel else { return }
                    presentQuickLook(model)
                }
                // ⌘F / ⌥⌘F 的键位仍归状态栏的过滤器（任务说明），这里只暴露无快捷键的意图。
                let panel = FilterPanelCoordinator.shared.state(for: tab.id)
                actions.toggleFilter = {
                    panel.isFilterBarVisible.toggle()
                    if panel.isFilterBarVisible { panel.focusToken += 1 }
                }

            case .query:
                actions.openScript = { QueryScriptActions.open(session: session, toasts: toasts) }
                actions.saveScriptAs = {
                    guard let model = tab.query as? QueryTabViewModel else { return }
                    QueryScriptActions.saveAs(model: model, tab: tab, toasts: toasts)
                }
                actions.cancelQuery = {
                    if let model = tab.query as? QueryTabViewModel { model.stop() }
                }
                actions.find = { QueryScriptActions.find() }

            default:
                break
            }
        }

        // 注释 / 缩进 / 反缩进尚未在编辑器上接线；导入导出界面未就绪 → 保持禁用。
        actions.toggleComment = nil
        actions.indent = nil
        actions.outdent = nil
        actions.toggleColumnFilter = nil
        actions.importCSV = nil
        actions.exportData = nil
        return actions
    }

    /// 工具栏按钮与菜单共用的一组动作。
    private var tableDataCommands: WorkspaceTableDataCommands {
        WorkspaceTableDataCommands(
            preview: { model in presentPreview(model) },
            commit: { model in commit(model) },
            discard: { model in requestDiscard(model) }
        )
    }

    // MARK: 标签导航 / 刷新

    private var activeIndex: Int? {
        session.tabs.firstIndex { $0.id == session.activeTabID }
    }

    private func selectRelative(offset: Int) {
        guard let index = activeIndex else { return }
        let target = index + offset
        guard session.tabs.indices.contains(target) else { return }
        session.selectTab(session.tabs[target])
    }

    /// `⌘R`：刷新对象树 + 当前标签（查询标签不重放）。
    private func refreshActiveTab() {
        Task {
            if let model = session.activeTab?.tableData as? TableDataViewModel {
                await model.refresh()
            } else if let model = session.activeTab?.tableStructure as? TableStructureViewModel {
                await model.refresh()
            } else if let model = session.activeTab?.objectDefinition as? ObjectDefinitionViewModel {
                await model.refresh()
            }
            await session.refreshObjects()
        }
    }

    // MARK: 关闭标签（三选一）

    private func closeActiveTab() {
        guard let tab = session.activeTab else { return }
        guard tab.hasPendingChanges else {
            session.closeTab(tab)
            return
        }
        switch WorkspacePendingChangeGuard.askToClose(tabTitle: tab.title) {
        case .cancel:
            return
        case .discard:
            discardAndClose(tab)
        case .commit:
            commitAndClose(tab)
        }
    }

    private func commitAndClose(_ tab: Tab) {
        confirmDialog = nil
        Task {
            if let model = tab.tableData as? TableDataViewModel {
                let statements = await model.previewStatements()
                do {
                    _ = try await model.commit()
                } catch let failure as CommitFailure {
                    let index = failure.statementIndex - 1
                    let row = statements.indices.contains(index) ? statements[index].identity : nil
                    commitFailureModel = model
                    commitFailure = CommitFailurePresentation(failure: failure, row: row)
                    return
                } catch {
                    logger.error("关闭标签前提交失败：\(String(describing: error), privacy: .public)")
                    WorkspacePendingChangeGuard.presentError(error, tabTitle: tab.title)
                    return
                }
            }
            session.closeTab(tab)
        }
    }

    private func discardAndClose(_ tab: Tab) {
        confirmDialog = nil
        Task {
            if let model = tab.tableData as? TableDataViewModel {
                await model.discardAll()
            }
            session.closeTab(tab)
        }
    }

    // MARK: 预览 / 提交 / 放弃

    private func presentPreview(_ model: TableDataViewModel) {
        Task {
            let statements = await model.previewStatements()
            guard !statements.isEmpty else { return }
            pendingPreview = WorkspacePreviewPresentation(model: model, statements: statements)
        }
    }

    private func commit(_ model: TableDataViewModel) {
        guard !model.isCommitting, model.isDirty else { return }
        Task {
            let statements = await model.previewStatements()
            do {
                let outcome = try await model.commit()
                toasts.show("已提交 \(outcome.executedCount) 处修改 · \(QueryTabLogic.elapsedText(outcome.elapsed))")
            } catch let failure as CommitFailure {
                let index = failure.statementIndex - 1
                let row = statements.indices.contains(index) ? statements[index].identity : nil
                commitFailureModel = model
                commitFailure = CommitFailurePresentation(failure: failure, row: row)
            } catch {
                logger.error("提交失败：\(String(describing: error), privacy: .public)")
                toasts.show((error as? MySQLError)?.title ?? "提交失败")
            }
        }
    }

    private func requestDiscard(_ model: TableDataViewModel) {
        let stats = model.pendingStats
        // 放弃多于 5 条，或包含删除 / 新增时先确认（specs/12-feedback.md §4）。
        if stats.total > 5 || stats.deletes > 0 || stats.inserts > 0 {
            confirmDialog = .discard(model)
        } else {
            Task { await model.discardAll() }
        }
    }

    // MARK: 行操作 / 快速查看

    private func currentSelection(in model: TableDataViewModel) -> Set<RowIdentity> {
        if !model.selectedRows.isEmpty { return model.selectedRows }
        if let focused = model.focusedRow { return [focused] }
        return []
    }

    private func duplicateRows(in model: TableDataViewModel) {
        let rows = currentSelection(in: model)
        guard !rows.isEmpty else { return }
        model.duplicateRows(rows)
    }

    private func deleteRows(in model: TableDataViewModel) {
        let rows = currentSelection(in: model)
        guard !rows.isEmpty else { return }
        model.deleteRows(rows)
    }

    private func presentQuickLook(_ model: TableDataViewModel) {
        guard let row = model.focusedRow,
              let column = model.focusedColumn,
              let tableColumn = model.allColumns.first(where: { $0.name == column }) else { return }
        let value = model.currentValue(row: row, column: column)
        let needsLoad = model.isTruncated(row: row, column: column)
            && model.fullValue(row: row, column: column) == nil

        quickLookController.show(title: "\(model.ref.table).\(column)",
                                 kind: tableColumn.kind,
                                 value: value,
                                 isLoading: needsLoad,
                                 error: nil)

        guard needsLoad else { return }
        Task {
            await model.loadFullValue(row: row, column: column)
            let loaded = model.fullValue(row: row, column: column) ?? value
            quickLookController.update(value: loaded, isLoading: false, error: model.fullValueError)
        }
    }

    // MARK: 只读提示 / 对象树同步

    private func announceReadOnlyIfNeeded() {
        guard session.isReadOnly else { return }
        announceReadOnly()
    }

    private func announceReadOnly() {
        toasts.show("该连接处于只读模式，所有写操作已被禁用。")
    }

    private func syncObjectTree() {
        objectTree.update(objects: session.objects, database: session.selectedDatabase)
    }

    // MARK: 确认弹窗绑定

    private var confirmDialogPresented: Binding<Bool> {
        Binding(get: { confirmDialog != nil },
                set: { if !$0 { confirmDialog = nil } })
    }

    private var confirmDialogTitle: String {
        guard let confirmDialog else { return "" }
        switch confirmDialog {
        case .close(let tab):
            return "「\(tab.title)」有未提交的修改"
        case .discard:
            return "放弃未提交的修改？"
        }
    }
}

// MARK: - 工作区确认弹窗

private enum WorkspaceConfirmDialog {
    case close(Tab)
    case discard(TableDataViewModel)
}

// MARK: - 待提交 SQL 预览

private struct WorkspacePreviewPresentation: Identifiable {
    let id = UUID()
    let model: TableDataViewModel
    let statements: [PendingSQLStatement]
}

// MARK: - 库切换面板（菜单「连接 → 切换数据库…」⌘K）

private struct WorkspaceDatabaseSwitcherSheet: View {

    @ObservedObject var session: ConnectionSession
    @Binding var isPresented: Bool

    @State private var search = ""

    private var databases: [String] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return session.databases }
        return session.databases.filter { $0.lowercased().contains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索数据库…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            Divider()

            if databases.isEmpty {
                Text("没有可访问的数据库")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(databases, id: \.self) { database in
                            Button {
                                select(database)
                            } label: {
                                HStack {
                                    Text(database).lineLimit(1)
                                    Spacer()
                                    if database == session.selectedDatabase {
                                        Image(systemName: "checkmark").font(.caption)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
            }
            .padding(12)
        }
        .frame(width: 320, height: 380)
    }

    private func select(_ database: String) {
        session.selectedDatabase = database
        isPresented = false
        Task { await session.refreshObjects() }
    }
}

// MARK: - 未提交改动守卫（关闭标签 / 断开连接 / 切换连接）

/// 关闭标签、断开连接、切换连接时的「提交 / 放弃 / 取消」三选一。
///
/// 用 AppKit `NSAlert` 是因为这些入口有的从菜单 `Commands` 触发、有的从工具栏触发，
/// 没有统一的 SwiftUI 展示层；文案与 `AppDelegate` 的退出确认保持一致。
/// 见 `specs/12-feedback.md` §4、`docs/tech-designs/08-pending-changes.md` §1 §5。
@MainActor
enum WorkspacePendingChangeGuard {

    enum Decision {
        case commit
        case discard
        case cancel
    }

    static func dirtyTabs(in session: ConnectionSession) -> [Tab] {
        session.tabs.filter(\.hasPendingChanges)
    }

    static func askToClose(tabTitle: String) -> Decision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(tabTitle)」有未提交的修改"
        alert.informativeText = "关闭前需要先处理这些改动。"
        alert.addButton(withTitle: "提交并关闭")
        alert.addButton(withTitle: "放弃并关闭")
        alert.addButton(withTitle: "取消")
        return decision(for: alert.runModal())
    }

    static func askToDisconnect(sessionName: String, dirtyCount: Int) -> Decision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(sessionName)」还有 \(dirtyCount) 个标签有未提交的修改"
        alert.informativeText = "断开或切换前需要先处理这些改动。"
        alert.addButton(withTitle: "提交并继续")
        alert.addButton(withTitle: "放弃并继续")
        alert.addButton(withTitle: "取消")
        return decision(for: alert.runModal())
    }

    /// 按决定处理一批脏标签；返回 `true` 表示可以继续（取消或提交失败时返回 `false`）。
    static func resolve(_ decision: Decision, tabs: [Tab]) async -> Bool {
        switch decision {
        case .cancel:
            return false
        case .discard:
            for tab in tabs {
                if let model = tab.tableData as? TableDataViewModel {
                    await model.discardAll()
                }
            }
            return true
        case .commit:
            for tab in tabs {
                guard let model = tab.tableData as? TableDataViewModel else { continue }
                do {
                    _ = try await model.commit()
                } catch {
                    logger.error("批量提交失败：\(String(describing: error), privacy: .public)")
                    presentError(error, tabTitle: tab.title)
                    return false
                }
            }
            return true
        }
    }

    /// 错误面板：标题一句话 + 原始错误原文 + 数据状态说明（specs/12-feedback.md §5）。
    static func presentError(_ error: Error, tabTitle: String?) {
        let alert = NSAlert()
        alert.alertStyle = .critical

        var text = ""
        if let mysqlError = error as? MySQLError {
            alert.messageText = mysqlError.title
            if let serverError = mysqlError.serverError {
                text = serverError.formatted
                if let hint = serverError.chineseHint {
                    text += "\n\n\(hint)"
                }
            } else {
                text = mysqlError.title
            }
        } else {
            alert.messageText = "提交未完成"
            text = String(describing: error)
        }

        if let tabTitle {
            alert.informativeText = "「\(tabTitle)」的修改尚未提交，返回后可以重试。\n\n\(text)"
        } else {
            alert.informativeText = "修改尚未提交，返回后可以重试。\n\n\(text)"
        }
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    private static func decision(for response: NSApplication.ModalResponse) -> Decision {
        switch response {
        case .alertFirstButtonReturn:
            return .commit
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }
}

// MARK: - 未选择连接

private struct WorkspaceNoSessionView: View {

    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var connections: ConnectionStore
    @EnvironmentObject private var toasts: ToastCenter

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("选择一个连接开始")
                .font(.title3)

            if connections.connections.isEmpty {
                Text("还没有连接")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(connections.connections) { connection in
                        Button {
                            connect(connection)
                        } label: {
                            HStack(spacing: 8) {
                                WorkspaceStatusDot(state: state(for: connection.id))
                                Text(connection.name.isEmpty ? connection.mysql.host : connection.name)
                                Spacer()
                                Text(connection.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 380)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 760, minHeight: 480)
    }

    private func state(for id: UUID) -> ConnectionState {
        sessionManager.session(id: id)?.state ?? .disconnected
    }

    private func connect(_ connection: Connection) {
        Task {
            do {
                _ = try await sessionManager.connect(connection, password: nil)
                toasts.show("已连接 \(connection.name)")
            } catch {
                logger.error("连接失败：\(String(describing: error), privacy: .public)")
                toasts.show((error as? MySQLError)?.title ?? "连接失败")
            }
        }
    }
}

// MARK: - 连接颜色带

private struct WorkspaceColorBand: View {

    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 2)
    }
}

// MARK: - 连接颜色映射

/// `ConnectionColor` → SwiftUI `Color`。独立命名空间，避免与其他 worker 的同名扩展冲突。
enum WorkspaceColorMapping {

    static func color(for color: ConnectionColor) -> Color {
        switch color {
        case .none: return Color.clear
        case .red: return Color.red
        case .orange: return Color.orange
        case .yellow: return Color.yellow
        case .green: return Color.green
        case .blue: return Color.blue
        case .purple: return Color.purple
        case .gray: return Color.gray
        }
    }
}

// MARK: - 连接状态点

/// 连接状态点：灰=未连接、黄=连接中、绿=正常、红=断开。
struct WorkspaceStatusDot: View {

    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }
}
