import AppKit
import SwiftUI

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
    @State private var didLoadSidebarState = false
    @State private var showOpenTable = false
    @State private var showDatabasePicker = false
    @State private var showConnectionList = false
    @State private var searchFocusRequest = 0
    @State private var pendingChanges = PendingChangesCoordinator()
    @State private var exportCenter = ExportRequestCenter()
    @State private var importRequest: ImportRequest?
    @State private var showDisableReadOnlyConfirmation = false
    /// 轻提示（`specs/12-feedback.md` §3）：顶部中间显示，2.5 秒后淡出。
    @State private var toastText: String?
    @State private var toastAction: ToastAction?
    @State private var toastToken = UUID()
    /// 短暂状态栏提示（如进入只读连接，`specs/09-readonly-mode.md` §5）。
    @State private var transientStatusMessage: String?
    @State private var transientStatusToken = UUID()
    /// 本会话是否曾经连上过：用于区分「首次连接」与「重连」（`specs/12-feedback.md` §3）。
    @State private var hasEverConnected = false

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
                            exportCenter.present(.table(database: object.database, table: object.name))
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
                onSwitchDatabase: { showDatabasePicker = true },
                transientMessage: transientStatusMessage,
                exportProgress: exportCenter.progressText
            )
        }
        .frame(minWidth: 860, minHeight: 560)
        .overlay(alignment: .top) {
            toastOverlay
        }
        .navigationTitle(windowTitle)
        .onAppear(perform: handleAppear)
        .onChange(of: session.state) { oldValue, newValue in
            handleStateChange(from: oldValue, to: newValue)
        }
        .onChange(of: showSidebar) { _, newValue in
            environment.workspace.sidebarVisible = newValue
        }
        .focusedSceneValue(\.workspaceActions, workspaceActions)
        .environment(pendingChanges)
        .environment(exportCenter)
        .confirmationDialog(
            pendingChanges.request?.title ?? "有未提交的修改",
            isPresented: Binding(
                get: { pendingChanges.request != nil },
                set: { if !$0 { pendingChanges.dismissWithoutDecision() } }
            ),
            titleVisibility: .visible,
            presenting: pendingChanges.request
        ) { _ in
            Button("提交") { pendingChanges.decide(.submit) }
            Button("放弃并关闭", role: .destructive) { pendingChanges.decide(.discard) }
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
        .sheet(item: $exportCenter.request) { request in
            ExportPanelView(
                session: session,
                source: request.source,
                onFinish: handleExportFinish,
                onProgress: { progress in
                    exportCenter.progressText = "正在导出… \(progress.displayText)"
                }
            )
        }
        .sheet(item: $importRequest) { request in
            ImportWizardView(session: session, defaultDatabase: request.database, defaultTable: request.table) { summary in
                // 导入完成后刷新对象树与当前数据（DDL/数据变化已由 session.execute 触发缓存失效），
                // 并按 `specs/12-feedback.md` §3 走轻提示。
                Task { await session.refreshObjects() }
                showToast(summary.message)
            }
        }
        .onChange(of: environment.preferences.showSystemDatabases) { _, _ in
            // 偏好改了立刻生效：重新拉一遍库列表（`specs/11-preferences.md` §6）。
            Task { await session.reloadDatabases() }
        }
        // 关闭只读模式前给一次轻确认（`specs/09-readonly-mode.md` §6）。
        .confirmationDialog(
            "确定要关闭「\(session.connection.name)」的只读模式吗？",
            isPresented: $showDisableReadOnlyConfirmation,
            titleVisibility: .visible
        ) {
            Button("取消", role: .cancel) {}
            Button("关闭只读模式", role: .destructive) { applyReadOnly(false) }
        } message: {
            Text("关闭后可以修改数据、执行写操作。")
        }
    }

    // MARK: 轻提示

    /// 轻提示里的可选动作按钮（如导出完成后的「在 Finder 中显示」）。
    struct ToastAction {
        var title: String
        var url: URL
    }

    /// 顶部中间的轻提示（复制成功 / 提交成功 / 重连 / 导出完成等）。
    @ViewBuilder
    private var toastOverlay: some View {
        if let toastText {
            HStack(spacing: 10) {
                Text(toastText)
                if let toastAction {
                    Button(toastAction.title) {
                        NSWorkspace.shared.activateFileViewerSelecting([toastAction.url])
                        self.toastAction = nil
                    }
                    .controlSize(.small)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    private func showToast(_ text: String, action: ToastAction? = nil) {
        toastText = text
        toastAction = action
        let token = UUID()
        toastToken = token
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard toastToken == token else { return }
            toastText = nil
            toastAction = nil
        }
    }

    /// 导出完成：清掉状态栏进度，勾选了「后台导出，完成后通知我」且成功时给轻提示
    /// （带「在 Finder 中显示」按钮，`specs/08-import-export.md` §1、`specs/12-feedback.md` §3）。
    private func handleExportFinish(_ summary: ExportSummary, notify: Bool) {
        exportCenter.progressText = nil
        guard notify, summary.isSuccess else { return }
        let action = summary.destinationURL.map { ToastAction(title: "在 Finder 中显示", url: $0) }
        showToast(summary.message, action: action)
    }

    /// 进入工作区：恢复侧栏状态，并在已连接且只读时给出状态栏短暂提示（`specs/09-readonly-mode.md` §5）。
    private func handleAppear() {
        loadSidebarStateIfNeeded()
        hasEverConnected = session.state.isConnected
        if session.state.isConnected, session.isReadOnly {
            showTransientStatus("该连接处于只读模式，所有写操作已被禁用。")
        }
    }

    /// 连接状态变化：首次连上且为只读 → 状态栏只读提示；之后重连成功 → `已重新连接` 轻提示。
    private func handleStateChange(
        from oldValue: SessionConnectionState,
        to newValue: SessionConnectionState
    ) {
        guard newValue.isConnected, !oldValue.isConnected else { return }
        if hasEverConnected {
            showToast("已重新连接")
        } else {
            hasEverConnected = true
            if session.isReadOnly {
                showTransientStatus("该连接处于只读模式，所有写操作已被禁用。")
            }
        }
    }

    /// 状态栏短暂提示：整条状态栏只显示它 2.5 秒（`specs/09-readonly-mode.md` §5）。
    private func showTransientStatus(_ text: String) {
        transientStatusMessage = text
        let token = UUID()
        transientStatusToken = token
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard transientStatusToken == token else { return }
            transientStatusMessage = nil
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

    /// 左侧栏显隐的持久化（L21、`specs/02-workspace.md` §5）。
    private func loadSidebarStateIfNeeded() {
        guard !didLoadSidebarState else { return }
        didLoadSidebarState = true
        showSidebar = environment.workspace.sidebarVisible
    }

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

    /// 切换只读模式并写回连接配置（`specs/09-readonly-mode.md` §6：状态要持久化）。
    private func applyReadOnly(_ value: Bool) {
        session.setReadOnly(value)
        var updated = session.connection
        updated.isReadOnly = value
        updated.updatedAt = environment.clock.now
        Task { try? await environment.connections.upsert(updated) }
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
            // `⌘↩` 按偏好「默认执行行为」分派：默认执行当前语句，可改为执行全部
            // （`specs/06-query-editor.md` §3）。
            executeStatement = { editor.executeDefault() }
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
                    exportCenter.present(tableModel.exportSource)
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
            toggleReadOnly: {
                if session.isReadOnly {
                    showDisableReadOnlyConfirmation = true
                } else {
                    applyReadOnly(true)
                }
            },
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
