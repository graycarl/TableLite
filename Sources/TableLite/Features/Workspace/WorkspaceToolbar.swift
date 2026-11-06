import SwiftUI

/// 工作区窗口工具栏（`specs/02-workspace.md` §2）。
///
/// 与系统标题栏合一（`docs/tech-designs/06-ui-layer.md` §10）：挂在 `WorkspaceView` 的
/// `.toolbar` 上，按钮样式由系统 toolbar 统一处理，不再自绘一条 `.bar` 横条。
///
/// 从左到右：连接切换器 → 窗口标题（库 / 标签）→ 快速打开 / 刷新 / 字段栏开关。
/// 变更操作不在这里，见 `PendingChangesBar`。
struct WorkspaceToolbar: ToolbarContent {

    let session: ConnectionSession
    var onQuickOpen: () -> Void
    var onRefresh: () -> Void
    var onToggleInspector: () -> Void
    var onShowConnections: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ConnectionSwitcher(session: session, onShowConnections: onShowConnections)
        }

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 2) {
                Button {
                    onQuickOpen()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("快速打开表 / 视图（⌘P）")
                .accessibilityLabel("快速打开")
                .accessibilityIdentifier("toolbar.quick-open")
                .disabled(session.objects.isEmpty)

                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新（⌘R）")
                .accessibilityLabel("刷新")
                .accessibilityIdentifier("toolbar.refresh")
                .disabled(!session.state.isConnected)

                Button {
                    onToggleInspector()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("显示 / 隐藏右侧字段栏")
                .accessibilityLabel("右侧字段栏")
                .accessibilityIdentifier("toolbar.inspector-toggle")
                .disabled(session.activeTab?.kind.isTableData != true)
            }
        }
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
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                SessionStatusDot(state: session.state)
                if session.isReadOnly {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(session.connection.name)
                    .font(AppFont.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .fixedSize()
        .help(connectionHelp)
        .accessibilityIdentifier("toolbar.connection-switcher")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            connectionMenu
                .frame(width: 300)
        }
    }

    private var connectionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("切换连接")
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 3)

            ForEach(environment.sessionManager.sessions) { candidate in
                Button {
                    environment.sessionManager.activeSessionID = candidate.id
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        SessionStatusDot(state: candidate.state)
                        if candidate.connection.isReadOnly {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Text(candidate.connection.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let database = candidate.selectedDatabase {
                            Text(database)
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if candidate.id == session.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .font(AppFont.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 3)

            Button("新建连接…") { dismissAnd { onShowConnections() } }
            Button("编辑当前连接…") { dismissAnd { onShowConnections() } }
            Button("重新连接") { isPresented = false; reconnect() }
            Button("断开连接") { isPresented = false; disconnect() }
        }
        .font(AppFont.body)
        .buttonStyle(.plain)
        .padding(6)
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

    private func dismissAnd(_ action: @escaping () -> Void) {
        isPresented = false
        DispatchQueue.main.async(execute: action)
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
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索表、视图…", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(openSelected)
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .accessibilityIdentifier("open-table.search")
            }
            .padding(10)

            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("没有匹配的对象")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, object in
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
                                    .padding(.vertical, 5)
                                    .background(
                                        index == selectedIndex
                                            ? Color.accentColor.opacity(0.14)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: AppRadius.s)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(object.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        guard filtered.indices.contains(newValue) else { return }
                        proxy.scrollTo(filtered[newValue].id, anchor: .center)
                    }
                }
            }

            Divider()
            HStack(spacing: 10) {
                Text("↑↓ 选择 · ↩ 打开 · Esc 关闭")
                    .font(AppFont.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 380, height: 420)
        .defaultFocus($searchFocused, true)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                searchFocused = true
            }
        }
        .onChange(of: search) { _, _ in selectedIndex = 0 }
        .onChange(of: filtered.count) { _, newValue in
            if selectedIndex >= newValue { selectedIndex = max(0, newValue - 1) }
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), filtered.count - 1)
    }

    private func openSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        open(filtered[selectedIndex])
        dismiss()
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
