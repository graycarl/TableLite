import SwiftUI

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
                    ObjectTreeSidebar(session: session, focusSearchRequest: searchFocusRequest)
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
        if let tab = session.activeTab {
            session.closeTab(tab)
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

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions(
            newQuery: newQuery,
            closeTab: closeActiveTab,
            importCSV: { },
            exportData: { },
            openScript: { },
            saveScriptAs: { },
            reconnect: {
                Task { try? await environment.sessionManager.reconnect(id: session.id) }
            },
            disconnect: {
                Task { await environment.sessionManager.disconnect(id: session.id) }
            },
            switchDatabase: { showDatabasePicker = true },
            refresh: {
                Task { await refresh() }
            },
            toggleReadOnly: { session.setReadOnly(!session.isReadOnly) },
            submitChanges: nil,
            previewSQL: nil,
            discardChanges: nil,
            cancelQuery: {
                (session.activeTab?.content as? TableDataViewModel)?.cancelInFlight()
            },
            toggleSidebar: { showSidebar.toggle() },
            toggleInspector: { environment.preferences.showInspector.toggle() },
            toggleConsoleLog: toggleConsoleLog,
            previousTab: { navigate(previous: true) },
            nextTab: { navigate(previous: false) },
            selectTab: { selectTab($0) },
            inspectorVisible: environment.preferences.showInspector,
            isReadOnly: session.isReadOnly,
            find: {
                showSidebar = true
                searchFocusRequest += 1
            },
            findColumns: nil
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
