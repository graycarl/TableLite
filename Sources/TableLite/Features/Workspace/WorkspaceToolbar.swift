import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 表数据变更操作入口

/// 工作区级表数据操作入口。工具栏按钮与菜单共用同一套实现，
/// 避免 sheet / alert / 快捷键重复（`docs/tech-designs/06-ui-layer.md` §5）。
struct WorkspaceTableDataCommands {
    var preview: (TableDataViewModel) -> Void
    var commit: (TableDataViewModel) -> Void
    var discard: (TableDataViewModel) -> Void
}

// MARK: - 工作区工具栏

/// 工具栏：连接切换器 → 标签前进后退 → 新建查询 / 打开表 → 变更操作组 → 字段栏开关。
/// 见 `specs/02-workspace.md` §2、`specs/03-data-browsing.md` §7、`specs/09-readonly-mode.md` §5。
struct WorkspaceToolbar: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var preferences: PreferencesStore
    /// 变更操作由工作区（菜单）与本工具栏共用。
    let tableDataCommands: WorkspaceTableDataCommands

    @State private var showingOpenTable = false

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceConnectionSwitcher(session: session, sessionManager: sessionManager)

            Divider().frame(height: 20)

            navigationButtons

            Divider().frame(height: 20)

            Button { session.newQueryTab() } label: {
                Text("+ 新建查询")
            }
            .help("新建查询标签（⌘T）")

            Button { showingOpenTable = true } label: {
                Text("+ 打开表…")
            }
            .disabled(!session.state.isConnected)
            .help("按表名搜索并打开表数据")

            Spacer(minLength: 12)

            ChangeOperationsView(session: session, commands: tableDataCommands)

            Divider().frame(height: 20)

            inspectorToggle
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(.bar)
        .sheet(isPresented: $showingOpenTable) {
            WorkspaceOpenTableSheet(session: session, isPresented: $showingOpenTable)
        }
    }

    // MARK: 前进 / 后退（切标签）

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button { selectRelative(offset: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoBack)
            .help("上一个标签（⌘[）")

            Button { selectRelative(offset: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoForward)
            .help("下一个标签（⌘]）")
        }
        .buttonStyle(.borderless)
    }

    private var activeIndex: Int? {
        session.tabs.firstIndex { $0.id == session.activeTabID }
    }

    private var canGoBack: Bool {
        (activeIndex ?? 0) > 0
    }

    private var canGoForward: Bool {
        guard let index = activeIndex else { return false }
        return index < session.tabs.count - 1
    }

    private func selectRelative(offset: Int) {
        guard let index = activeIndex else { return }
        let target = index + offset
        guard session.tabs.indices.contains(target) else { return }
        session.selectTab(session.tabs[target])
    }

    // MARK: 右侧字段栏开关

    private var isTableDataActive: Bool {
        guard let kind = session.activeTab?.kind else { return false }
        if case .tableData = kind { return true }
        return false
    }

    private var inspectorToggle: some View {
        Button {
            preferences.showRowInspector.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
                .opacity(preferences.showRowInspector ? 1 : 0.45)
        }
        .buttonStyle(.borderless)
        .disabled(!isTableDataActive)
        .help(isTableDataActive
              ? "显示 / 隐藏右侧字段栏"
              : "右侧字段栏只在表数据标签里可用")
    }
}

// MARK: - 连接切换器

private struct WorkspaceConnectionSwitcher: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var sessionManager: SessionManager
    @EnvironmentObject private var toasts: ToastCenter

    var body: some View {
        Menu {
            ForEach(sessionManager.sessions) { candidate in
                Button {
                    switchTo(candidate)
                } label: {
                    // Menu 项内用文字承载，状态点用符号表达。
                    Text(menuTitle(candidate))
                }
            }
            if !sessionManager.sessions.isEmpty { Divider() }
            Button("新建连接…") { toasts.show("连接编辑界面即将实现") }
            Button("编辑当前连接…") { toasts.show("连接编辑界面即将实现") }
            Divider()
            Button("重新连接") { reconnect() }
            Button("断开连接") { disconnect() }
        } label: {
            HStack(spacing: 6) {
                WorkspaceStatusDot(state: session.state)
                Text(displayName)
                    .lineLimit(1)
                if let database = session.selectedDatabase, !database.isEmpty {
                    Text(database)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("切换连接")
    }

    private var displayName: String {
        session.displayName.isEmpty ? session.connection.mysql.host : session.displayName
    }

    private func menuTitle(_ candidate: ConnectionSession) -> String {
        var text = candidate.displayName.isEmpty ? candidate.connection.mysql.host : candidate.displayName
        if let database = candidate.selectedDatabase, !database.isEmpty {
            text += "    \(database)"
        }
        return text
    }

    private func reconnect() {
        Task {
            do {
                try await sessionManager.reconnect(id: session.id)
                toasts.show("已重新连接")
            } catch {
                logger.error("重新连接失败：\(String(describing: error), privacy: .public)")
                toasts.show((error as? MySQLError)?.title ?? "重新连接失败")
            }
        }
    }

    /// 切换连接：当前连接还有未提交改动时先三选一（提交 / 放弃 / 取消）。
    private func switchTo(_ candidate: ConnectionSession) {
        guard candidate.id != session.id else { return }
        let dirty = WorkspacePendingChangeGuard.dirtyTabs(in: session)
        guard !dirty.isEmpty else {
            sessionManager.activeSessionID = candidate.id
            return
        }
        let decision = WorkspacePendingChangeGuard.askToDisconnect(sessionName: displayName,
                                                                  dirtyCount: dirty.count)
        Task {
            let proceed = await WorkspacePendingChangeGuard.resolve(decision, tabs: dirty)
            if proceed { sessionManager.activeSessionID = candidate.id }
        }
    }

    private func disconnect() {
        let dirty = WorkspacePendingChangeGuard.dirtyTabs(in: session)
        guard !dirty.isEmpty else {
            Task {
                await sessionManager.disconnect(id: session.id)
                toasts.show("连接已断开")
            }
            return
        }
        let decision = WorkspacePendingChangeGuard.askToDisconnect(sessionName: displayName,
                                                                  dirtyCount: dirty.count)
        Task {
            let proceed = await WorkspacePendingChangeGuard.resolve(decision, tabs: dirty)
            guard proceed else { return }
            await sessionManager.disconnect(id: session.id)
            toasts.show("连接已断开")
        }
    }
}

// MARK: - 变更操作组

private struct ChangeOperationsView: View {

    @ObservedObject var session: ConnectionSession
    let commands: WorkspaceTableDataCommands

    var body: some View {
        HStack(spacing: 6) {
            if session.isReadOnly {
                Text("只读模式：写操作已被禁用")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let tab = session.activeTab {
                ActiveChangeOperations(tab: tab, session: session, commands: commands)
                    .id(tab.id)
            } else {
                DisabledChangeOperations()
            }
        }
    }
}

private struct ActiveChangeOperations: View {

    @ObservedObject var tab: Tab
    @ObservedObject var session: ConnectionSession
    let commands: WorkspaceTableDataCommands

    private var viewModel: TableDataViewModel? {
        tab.tableData as? TableDataViewModel
    }

    var body: some View {
        if let viewModel {
            ChangeOperationsButtons(viewModel: viewModel, session: session, commands: commands)
        } else {
            DisabledChangeOperations()
        }
    }
}

private struct DisabledChangeOperations: View {

    var body: some View {
        HStack(spacing: 6) {
            Button("放弃") {}.disabled(true)
            Button("预览") {}.disabled(true)
            Button("提交") {}.disabled(true)
        }
        .buttonStyle(.bordered)
    }
}

private struct ChangeOperationsButtons: View {

    @ObservedObject var viewModel: TableDataViewModel
    @ObservedObject var session: ConnectionSession
    let commands: WorkspaceTableDataCommands

    private var count: Int { viewModel.pendingStats.total }
    private var isDirty: Bool { !viewModel.pending.isEmpty }
    private var isReadOnly: Bool { session.isReadOnly }
    private var isBusy: Bool { viewModel.isCommitting }

    var body: some View {
        HStack(spacing: 6) {
            // 提交进度：`正在提交 3/7…`（specs/12-feedback.md §1）。
            if let progress = viewModel.commitProgress {
                ProgressView()
                    .controlSize(.small)
                Text("正在提交 \(progress.completed)/\(progress.total)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("放弃(\(count))") { commands.discard(viewModel) }
                .disabled(!isDirty || isBusy)
                .help("放弃全部未提交的修改（⇧⌘⌫）")

            Button("预览(\(count))") { commands.preview(viewModel) }
                .disabled(!isDirty || isBusy)
                .help("预览将要执行的 SQL（⇧⌘P）")

            Button("提交(\(count))") { commands.commit(viewModel) }
                .disabled(!isDirty || isReadOnly || isBusy)
                .help(isReadOnly
                      ? "该连接处于只读模式，无法提交修改"
                      : (isDirty ? "提交 \(count) 处修改（⌘S）" : "没有待提交的修改"))
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - 待提交 SQL 预览面板

/// 预览面板：把 `PendingChangeStore` 生成的语句逐条列出，与提交时下发的完全一致。
struct WorkspacePendingSQLSheet: View {

    @ObservedObject var viewModel: TableDataViewModel
    @Binding var isPresented: Bool

    @State private var statements: [PendingSQLStatement] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("将要执行的 SQL").font(.headline)
                Spacer()
                Text("共 \(statements.count) 条")
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if statements.isEmpty {
                    Text("没有待执行的语句")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(statements) { statement in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(statement.id + 1).")
                                        .foregroundStyle(.secondary)
                                    Text(statement.text)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("关闭") { isPresented = false }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            statements = await viewModel.previewStatements()
            isLoading = false
        }
    }
}

// MARK: - 打开表搜索面板

private struct WorkspaceOpenTableSheet: View {

    @ObservedObject var session: ConnectionSession
    @Binding var isPresented: Bool

    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var matches: [DatabaseObject] {
        let tables = session.objects.filter { $0.kind == .table }
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return Array(tables.prefix(50)) }
        return tables.filter { $0.name.lowercased().contains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索表名…", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(12)

            Divider()

            if matches.isEmpty {
                Text("没有匹配的表")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches) { object in
                    Button {
                        open(object)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "tablecells")
                                .foregroundStyle(.secondary)
                            Text(object.name)
                            Spacer()
                            if let estimate = object.rowEstimate {
                                Text(verbatim: "\(estimate) 行")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
            }
            .padding(12)
        }
        .frame(width: 420, height: 460)
        .onAppear { searchFocused = true }
    }

    private func open(_ object: DatabaseObject) {
        let database = session.selectedDatabase ?? session.connection.mysql.database
        guard !database.isEmpty else { return }
        session.openTableData(TableRef(database: database, table: object.name))
        isPresented = false
    }
}
