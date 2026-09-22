import SwiftUI

/// 导出请求（`Features/ImportExport/ExportPanelView` 的挂载载体）。
private struct ExportRequest: Identifiable {
    let id = UUID()
    let source: ExportSource
}

/// 导入请求（`Features/ImportExport/ImportWizardView` 的挂载载体）。
private struct ImportRequest: Identifiable {
    let id = UUID()
    let database: String?
    let table: String?
}

/// 工作区主界面（`specs/02-workspace.md` §1）。
///
/// 纵向四层：工具栏 → 连接颜色带（2pt）→ 主体区 → 状态栏。
/// 主体区横向：左侧栏（可拖宽 / 可隐藏）↔ 标签内容区 ↔ 右侧字段栏（仅表数据标签）。
///
/// 菜单与快捷键通过 `.focusedSceneValue(\.workspaceActions, ...)` 暴露给 `TableLiteCommands`。
struct WorkspaceView: View {

    let session: ConnectionSession

    @Environment(AppEnvironment.self) private var environment

    @State private var showSidebar = true
    @State private var showOpenTable = false
    @State private var showDatabasePicker = false
    @State private var showConnectionList = false
    @State private var searchFocusRequest = 0
    @State private var pendingChanges = PendingChangesCoordinator()
    @State private var exportRequest: ExportRequest?
    @State private var importRequest: ImportRequest?

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(
                session: session,
                onNavigate: { previous in navigate(previous: previous) },
                onNewQuery: newQuery,
                onOpenTable: { showOpenTable = true },
                onToggleInspector: { environment.preferences.showInspector.toggle() },
                onShowConnections: { showConnectionList = true }
            )

            Rectangle()
                .fill(session.connection.color.swiftUIColor)
                .frame(height: 2)

            HStack(spacing: 0) {
                if showSidebar {
                    ObjectTreeSidebar(
                        session: session,
                        focusSearchRequest: searchFocusRequest,
                        onExport: { object in
                            exportRequest = ExportRequest(source: .table(database: object.database, table: object.name))
                        },
                        onImportCSV: { object in
                            importRequest = ImportRequest(database: object.database, table: object.name)
                        }
                    )
                        .frame(width: environment.preferences.sidebarWidth)
                    ResizeHandle { delta in
                        environment.preferences.sidebarWidth += Double(delta)
                    }
                }

                TabContainerView(session: session, onNewQuery: newQuery)

                if showsInspector {
                    ResizeHandle { delta in
                        environment.preferences.inspectorWidth -= Double(delta)
                    }
                    inspector
                        .frame(width: environment.preferences.inspectorWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StatusBarView(
                session: session,
                onEditConnection: { showConnectionList = true },
                onSwitchDatabase: { showDatabasePicker = true }
            )
        }
        .frame(minWidth: 860, minHeight: 560)
        .navigationTitle(windowTitle)
        .focusedSceneValue(\.workspaceActions, workspaceActions)
        .environment(pendingChanges)
        .confirmationDialog(
            pendingChanges.request?.title ?? "有未提交的修改",
            isPresented: Binding(
                get: { pendingChanges.request != nil },
                set: { if !$0 { pendingChanges.dismissWithoutDecision() } }
            ),
            titleVisibility: .visible,
            presenting: pendingChanges.request
        ) { _ in
            Button("提交并继续") { pendingChanges.decide(.submit) }
            Button("放弃修改", role: .destructive) { pendingChanges.decide(.discard) }
            Button("取消", role: .cancel) { pendingChanges.decide(.cancel) }
        } message: { request in
            Text(request.message)
        }
        .sheet(isPresented: $showOpenTable) {
            OpenTableSheet(session: session)
        }
        .sheet(isPresented: $showDatabasePicker) {
            VStack(spacing: 0) {
                Text("切换数据库")
                    .font(.headline)
                    .padding(.top, 12)
                DatabasePickerList(session: session) { showDatabasePicker = false }
            }
            .frame(width: 320, height: 420)
        }
        .sheet(isPresented: $showConnectionList) {
            ConnectionsView()
        }
        .sheet(item: $exportRequest) { request in
            ExportPanelView(session: session, source: request.source)
        }
        .sheet(item: $importRequest) { request in
            ImportWizardView(session: session, defaultDatabase: request.database, defaultTable: request.table) { _ in
                // 导入完成后刷新对象树与当前页（DDL/数据变化已由 session.execute 触发缓存失效）
                Task { await session.refreshObjects() }
            }
        }
    }

    // MARK: 右侧字段栏

    private var showsInspector: Bool {
        environment.preferences.showInspector && (session.activeTab?.kind.isTableData ?? false)
    }

    /// 字段栏是表数据网格选区的 SwiftUI 投影（`14-row-inspector.md` §2）。
    /// 本阶段只读；T9 在同一位置换成可编辑版本。
    @ViewBuilder
    private var inspector: some View {
        if let viewModel = session.activeTab?.content as? TableDataViewModel {
            RowInspectorView(viewModel: viewModel)
        } else {
            inspectorPlaceholder
        }
    }

    /// 字段栏未就绪时的占位（标签尚未装配 ViewModel）。
    private var inspectorPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("选中一行以查看和编辑它的字段")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("右侧字段栏待 W3/W4 实现")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: 标题

    private var windowTitle: String {
        var title = session.connection.name
        if session.isReadOnly {
            title += "（只读）"
        }
        if let database = session.selectedDatabase {
            title += " — \(database)"
        }
        return title
    }

    // MARK: 动作

    private func newQuery() {
        session.newQueryTab()
    }

    private func closeActiveTab() {
        guard let tab = session.activeTab else { return }
        Task {
            if await pendingChanges.resolveCloseAnyTab(tab: tab) {
                session.closeTab(tab)
            }
        }
    }

    private func navigate(previous: Bool) {
        let count = session.tabs.count
        guard count > 0 else { return }
        let current = session.tabs.firstIndex { $0.id == session.activeTabID } ?? 0
        let target = previous
            ? TabNavigator.previousIndex(current: current, count: count)
            : TabNavigator.nextIndex(current: current, count: count)
        if let target {
            session.selectTab(session.tabs[target])
        }
    }

    private func selectTab(_ number: Int) {
        guard let index = TabNavigator.index(forShortcut: number, count: session.tabs.count) else { return }
        session.selectTab(session.tabs[index])
    }

    private func toggleConsoleLog() {
        if let tab = session.tabs.first(where: { $0.kind == .consoleLog }) {
            if session.activeTabID == tab.id {
                session.closeTab(tab)
            } else {
                session.selectTab(tab)
            }
        } else {
            session.openConsoleLogTab()
        }
    }

    private func refresh() async {
        await session.meta.invalidateAll()
        await session.reloadDatabases()
        if let reload = session.activeTab?.reloadAfterReconnect {
            await reload()
        }
    }

    // MARK: 变更操作组与确认

    /// 当前前台表数据标签的 ViewModel。
    private var activeTableViewModel: TableDataViewModel? {
        session.activeTab?.content as? TableDataViewModel
    }

    /// 当前前台查询编辑器 ViewModel（查询标签且已装配）。
    private var activeQueryEditor: QueryEditorViewModel? {
        guard session.activeTab?.kind.isQuery == true else { return nil }
        return session.activeTab?.content as? QueryEditorViewModel
    }

    private func openScript() {
        guard let (url, text) = ScriptFileController.openPanel() else { return }
        let tab = session.newQueryTab()
        tab.filePath = url.path
        tab.customTitle = url.lastPathComponent
        tab.initialSQL = text
    }

    private var pendingSubmitAction: (@MainActor () -> Void)? {
        guard let model = activeTableViewModel else { return nil }
        return { model.requestSubmit() }
    }

    private var pendingPreviewAction: (@MainActor () -> Void)? {
        guard let model = activeTableViewModel else { return nil }
        return { model.presentPreview() }
    }

    private var pendingDiscardAction: (@MainActor () -> Void)? {
        guard let model = activeTableViewModel else { return nil }
        return { model.requestDiscard() }
    }

    /// 断开连接前先处理未提交改动。
    private func requestDisconnect() {
        Task {
            if await pendingChanges.resolveLeave(session: session) {
                await environment.sessionManager.disconnect(id: session.id)
            }
        }
    }

    private var workspaceActions: WorkspaceActions {
        let tableModel = activeTableViewModel
        let editor = activeQueryEditor
        let findAction: @MainActor () -> Void = {
            // 表数据标签前台时 `⌘F` 开关行过滤器；查询编辑器前台时弹系统查找条；
            // 否则聚焦对象树搜索框（`specs/02-workspace.md` §7、§9）。
            if let editor {
                editor.requestFind()
            } else if let tableModel {
                tableModel.toggleFilterVisible()
            } else {
                showSidebar = true
                searchFocusRequest += 1
            }
        }
        let findColumnsAction: (@MainActor () -> Void)? = {
            guard let tableModel else { return nil }
            return { tableModel.presentColumnFilter() }
        }()
        let cancelAction: @MainActor () -> Void = {
            if let editor {
                editor.stop()
            } else {
                tableModel?.cancelInFlight()
            }
        }
        let saveAsAction: @MainActor () -> Void = { editor?.saveScriptAs() }
        var saveAction: (@MainActor () -> Void)?
        if let editor {
            saveAction = { editor.saveScript() }
        }
        var executeStatement: (@MainActor () -> Void)?
        var executeAll: (@MainActor () -> Void)?
        var toggleComment: (@MainActor () -> Void)?
        var indentSelection: (@MainActor () -> Void)?
        var outdentSelection: (@MainActor () -> Void)?
        if let editor {
            executeStatement = { editor.executeCurrentStatement() }
            executeAll = { editor.executeAll() }
            toggleComment = { editor.requestCommand(.toggleComment) }
            indentSelection = { editor.requestCommand(.indent) }
            outdentSelection = { editor.requestCommand(.dedent) }
        }
        return WorkspaceActions(
            newQuery: newQuery,
            closeTab: closeActiveTab,
            importCSV: { importRequest = ImportRequest(database: session.selectedDatabase, table: nil) },
            exportData: {
                if let tableModel = activeTableViewModel {
                    exportRequest = ExportRequest(source: .table(database: tableModel.database, table: tableModel.table))
                } else {
                    // 没有表数据标签时退化为「先选表」：打开对象树搜索
                    showSidebar = true
                    searchFocusRequest += 1
                }
            },
            openScript: openScript,
            saveScript: saveAction,
            saveScriptAs: saveAsAction,
            reconnect: {
                Task { try? await environment.sessionManager.reconnect(id: session.id) }
            },
            disconnect: requestDisconnect,
            switchDatabase: { showDatabasePicker = true },
            refresh: {
                Task { await refresh() }
            },
            toggleReadOnly: { session.setReadOnly(!session.isReadOnly) },
            submitChanges: pendingSubmitAction,
            previewSQL: pendingPreviewAction,
            discardChanges: pendingDiscardAction,
            cancelQuery: cancelAction,
            executeStatement: executeStatement,
            executeAllStatements: executeAll,
            toggleComment: toggleComment,
            indentSelection: indentSelection,
            outdentSelection: outdentSelection,
            toggleSidebar: { showSidebar.toggle() },
            toggleInspector: { environment.preferences.showInspector.toggle() },
            toggleConsoleLog: toggleConsoleLog,
            previousTab: { navigate(previous: true) },
            nextTab: { navigate(previous: false) },
            selectTab: { selectTab($0) },
            inspectorVisible: environment.preferences.showInspector,
            isReadOnly: session.isReadOnly,
            pendingChangeCount: tableModel?.pendingCount ?? 0,
            find: findAction,
            findColumns: findColumnsAction
        )
    }
}

extension ConnectionColor {
    /// 连接颜色 → SwiftUI 颜色。`none` 不画颜色带。
    var swiftUIColor: Color {
        switch self {
        case .none: return .clear
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}
