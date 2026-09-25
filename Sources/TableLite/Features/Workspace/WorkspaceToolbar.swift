import SwiftUI

/// 工作区窗口工具栏（`specs/02-workspace.md` §2）。
///
/// 与系统标题栏合一（`docs/tech-designs/06-ui-layer.md` §10）：挂在 `WorkspaceView` 的
/// `.toolbar` 上，按钮样式由系统 toolbar 统一处理，不再自绘一条 `.bar` 横条。
///
/// 从左到右：连接切换器 → 标签前进/后退 → `+ 新建查询` / `+ 打开表…` →
/// 变更操作组 → 右侧字段栏开关。
struct WorkspaceToolbar: ToolbarContent {

    let session: ConnectionSession
    var onNavigate: (Bool) -> Void
    var onNewQuery: () -> Void
    var onOpenTable: () -> Void
    var onToggleInspector: () -> Void
    var onShowConnections: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ConnectionSwitcher(session: session, onShowConnections: onShowConnections)
        }

        ToolbarItem {
            WorkspaceNavigationButtons(session: session, onNavigate: onNavigate)
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: AppSpacing.s) {
                Button {
                    onNewQuery()
                } label: {
                    Label("新建查询", systemImage: "plus")
                }

                Button {
                    onOpenTable()
                } label: {
                    Label("打开表…", systemImage: "magnifyingglass")
                }
                .disabled(session.objects.isEmpty)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            WorkspaceChangeButtons(session: session, onToggleInspector: onToggleInspector)
        }
    }
}

/// 标签前进 / 后退（`⌘[` / `⌘]`）。
private struct WorkspaceNavigationButtons: View {

    let session: ConnectionSession
    var onNavigate: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button {
                onNavigate(true)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .help("上一个标签")
            .disabled(session.tabs.isEmpty)

            Button {
                onNavigate(false)
            } label: {
                Image(systemName: "chevron.forward")
            }
            .help("下一个标签")
            .disabled(session.tabs.isEmpty)
        }
    }
}

/// 变更操作组（`specs/02-workspace.md` §2）+ 右侧字段栏开关。
///
/// 变更操作组：放弃 / 预览(N) / 提交(N)。条数为 0 时整体禁用；只读连接上「提交」始终禁用并说明原因。
private struct WorkspaceChangeButtons: View {

    let session: ConnectionSession
    var onToggleInspector: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Button("放弃") { activeTableViewModel?.requestDiscard() }
                .disabled(!changeButtonsEnabled)
            Button("预览(\(pendingCount))") { activeTableViewModel?.presentPreview() }
                .disabled(!changeButtonsEnabled)
            Button("提交(\(pendingCount))") { activeTableViewModel?.requestSubmit() }
                .disabled(!changeButtonsEnabled || session.isReadOnly)
                .help(submitHint)

            Divider().frame(height: 18)

            Button {
                onToggleInspector()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("显示 / 隐藏右侧字段栏")
            .disabled(!isTableDataTab)
        }
    }

    private var isTableDataTab: Bool {
        session.activeTab?.kind.isTableData ?? false
    }

    private var activeTableViewModel: TableDataViewModel? {
        session.activeTab?.content as? TableDataViewModel
    }

    private var pendingCount: Int {
        activeTableViewModel?.pendingCount ?? 0
    }

    private var changeButtonsEnabled: Bool {
        isTableDataTab && pendingCount > 0
    }

    private var submitHint: String {
        if session.isReadOnly { return "该连接处于只读模式，无法提交修改" }
        return pendingCount == 0 ? "暂无未提交的修改" : "提交修改（⌘↩）"
    }
}

/// 连接切换器（`specs/02-workspace.md` §3）。
///
/// 列出所有会话（含未连接的恢复会话）；切换只改 `activeSessionID`，不断开连接。
struct ConnectionSwitcher: View {

    let session: ConnectionSession
    var onShowConnections: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(PendingChangesCoordinator.self) private var pendingChanges

    var body: some View {
        Menu {
            ForEach(environment.sessionManager.sessions) { candidate in
                Button {
                    environment.sessionManager.activeSessionID = candidate.id
                } label: {
                    HStack {
                        SessionStatusDot(state: candidate.state)
                        if candidate.connection.isReadOnly {
                            Image(systemName: "lock.fill")
                        }
                        Text(candidate.connection.name)
                        Spacer()
                        if let database = candidate.selectedDatabase {
                            Text(database)
                        }
                        if candidate.id == session.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button("新建连接…") { onShowConnections() }
            Button("编辑当前连接…") { onShowConnections() }
            Button("重新连接") { reconnect() }
            Button("断开") { disconnect() }
        } label: {
            HStack(spacing: 6) {
                SessionStatusDot(state: session.state)
                if session.isReadOnly {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                }
                Text(session.connection.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(connectionHelp)
    }

    /// 工具栏连接切换器的悬停详情：连接信息 + 只读标记 + SSH 隧道本地端口
    /// （原底部状态栏的连接信息，状态栏已在 2026-09-24 去掉）。
    private var connectionHelp: String {
        WorkspaceStatusText.connectionTooltip(
            lineParts: WorkspaceStatusText.connectionLineParts(
                connection: session.connection,
                state: session.state,
                database: session.selectedDatabase,
                serverInfo: session.serverInfo,
                isReadOnly: session.isReadOnly
            ),
            tunnelLine: session.tunnelEndpoint.map {
                WorkspaceStatusText.tunnelDetailLine(host: $0.host, port: $0.port)
            }
        )
    }

    private func reconnect() {
        Task { try? await environment.sessionManager.reconnect(id: session.id) }
    }

    private func disconnect() {
        Task {
            if await pendingChanges.resolveLeave(session: session) {
                await environment.sessionManager.disconnect(id: session.id)
            }
        }
    }
}

/// `+ 打开表…` 弹出的表名搜索框（`specs/02-workspace.md` §2）。
struct OpenTableSheet: View {

    let session: ConnectionSession

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索表、视图…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(10)

            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("没有匹配的对象")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { object in
                            Button {
                                open(object)
                                dismiss()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: object.kind == .view ? "eye" : "tablecells")
                                        .font(.caption)
                                        .foregroundStyle(object.kind == .view ? .purple : .secondary)
                                        .frame(width: 14)
                                    Text(object.name).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 420)
    }

    private var filtered: [TableInfo] {
        ObjectTreeModel.filtered(session.objects, query: search)
    }

    private func open(_ object: TableInfo) {
        switch object.kind {
        case .table:
            session.openTableData(database: object.database, table: object.name)
        case .view:
            session.openObjectDefinition(database: object.database, object: object.name)
        }
    }
}
