import SwiftUI

/// 顶部工具栏（`specs/02-workspace.md` §2）。
///
/// 从左到右：连接切换器 → 标签前进/后退 → `+ 新建查询` / `+ 打开表…` →
/// 变更操作组 → 右侧字段栏开关。
struct WorkspaceToolbar: View {

    let session: ConnectionSession
    var onNavigate: (Bool) -> Void
    var onNewQuery: () -> Void
    var onOpenTable: () -> Void
    var onToggleInspector: () -> Void
    var onShowConnections: () -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: 8) {
            ConnectionSwitcher(session: session, onShowConnections: onShowConnections)

            Divider().frame(height: 18)

            navButton(systemImage: "chevron.backward", help: "上一个标签") { onNavigate(true) }
                .disabled(session.tabs.isEmpty)
            navButton(systemImage: "chevron.forward", help: "下一个标签") { onNavigate(false) }
                .disabled(session.tabs.isEmpty)

            Spacer(minLength: 8)

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

            Spacer(minLength: 8)

            changeButtons

            Divider().frame(height: 18)

            Button {
                onToggleInspector()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("显示 / 隐藏右侧字段栏")
            .disabled(!isTableDataTab)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var isTableDataTab: Bool {
        session.activeTab?.kind.isTableData ?? false
    }

    /// 变更操作组：本阶段没有网格，整体禁用；条数为 0 时也应禁用（`specs/02-workspace.md` §2）。
    private var changeButtons: some View {
        HStack(spacing: 6) {
            Button("放弃") { }
                .disabled(true)
            Button("预览") { }
                .disabled(true)
            Button("提交修改") { }
                .disabled(true)
                .help(isReadOnlyHint)
        }
    }

    private var isReadOnlyHint: String {
        session.isReadOnly ? "该连接处于只读模式" : "暂无未提交的修改"
    }

    private func navButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .help(help)
    }
}

/// 连接切换器（`specs/02-workspace.md` §3）。
///
/// 列出所有会话（含未连接的恢复会话）；切换只改 `activeSessionID`，不断开连接。
struct ConnectionSwitcher: View {

    let session: ConnectionSession
    var onShowConnections: () -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Menu {
            ForEach(environment.sessionManager.sessions) { candidate in
                Button {
                    environment.sessionManager.activeSessionID = candidate.id
                } label: {
                    HStack {
                        SessionStatusDot(state: candidate.state)
                        Text(candidate.connection.name)
                        if candidate.connection.isReadOnly {
                            Image(systemName: "lock.fill")
                        }
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
            Button("断开连接") { disconnect() }
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
        .fixedSize()
    }

    private func reconnect() {
        Task { try? await environment.sessionManager.reconnect(id: session.id) }
    }

    private func disconnect() {
        Task { await environment.sessionManager.disconnect(id: session.id) }
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
