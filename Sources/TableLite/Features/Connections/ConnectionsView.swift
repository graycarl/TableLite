import SwiftUI

/// 连接管理入口（`specs/01-connections.md`）。
///
/// 无参 init；依赖从 `@Environment(AppEnvironment.self)` 取，由 RootView 在
/// 「无活动会话 / 用户打开连接管理」时挂载。
///
/// 连接成功后不做窗口切换：`SessionManager.activeSession` 变化后由 RootView 决定显示什么。
struct ConnectionsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: ConnectionListViewModel?

    init() {}

    var body: some View {
        Group {
            if let viewModel {
                ConnectionListContent(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            if viewModel == nil {
                viewModel = ConnectionListViewModel(environment: environment)
            }
            await viewModel?.load()
        }
    }
}

// MARK: - 列表内容

private struct ConnectionListContent: View {

    @Bindable var viewModel: ConnectionListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            banners
            content
            Divider()
            bottomBar
        }
        .sheet(isPresented: $viewModel.isFormPresented) {
            ConnectionFormView(form: $viewModel.formState, viewModel: viewModel)
        }
        .sheet(item: $viewModel.failurePresentation) { presentation in
            ConnectionFailureDetailView(
                failure: presentation.failure,
                connectionName: presentation.connection?.name,
                onReconnect: {
                    guard let connection = presentation.connection else { return }
                    viewModel.failurePresentation = nil
                    Task { await viewModel.reconnect(connection) }
                },
                onClose: { viewModel.failurePresentation = nil }
            )
        }
        .sheet(item: $viewModel.passwordPrompt) { prompt in
            ConnectionPasswordPromptView(
                connection: prompt.connection,
                onSubmit: { password, remember in
                    Task { await viewModel.submitPasswordPrompt(password: password, remember: remember) }
                },
                onCancel: { viewModel.cancelPasswordPrompt() }
            )
        }
        .alert(
            "确定要删除连接「\(viewModel.pendingDeletion?.name ?? "")」吗？",
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: { if !$0 { viewModel.pendingDeletion = nil } }
            ),
            presenting: viewModel.pendingDeletion
        ) { connection in
            Button("取消", role: .cancel) { viewModel.pendingDeletion = nil }
            Button("删除", role: .destructive) {
                Task { await viewModel.delete(connection) }
            }
        } message: { _ in
            Text("同时会删除保存在系统钥匙串里的密码。\n此操作不可撤销。")
        }
        .confirmationDialog(
            "有未提交的修改",
            isPresented: Binding(
                get: { viewModel.pendingChangesDeletion != nil },
                set: { if !$0 { viewModel.pendingChangesDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("提交并删除", role: .destructive) {
                Task { await viewModel.confirmDeleteWithPendingChanges(.submit) }
            }
            Button("放弃修改并删除", role: .destructive) {
                Task { await viewModel.confirmDeleteWithPendingChanges(.discard) }
            }
            Button("取消", role: .cancel) {
                Task { await viewModel.confirmDeleteWithPendingChanges(.cancel) }
            }
        } message: {
            Text("这个连接有未提交的修改。删除连接会一并关闭它的会话。")
        }
    }

    // MARK: 头部与提示

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TableLite")
                .font(.largeTitle.bold())
            Text("macOS 原生 MySQL 客户端")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var banners: some View {
        ForEach(Array(viewModel.notices.enumerated()), id: \.offset) { item in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(item.element)
                    .font(.callout)
                Spacer()
                Button("知道了") { Task { await viewModel.dismissNotices() } }
                    .controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        if let error = viewModel.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.callout)
                Spacer()
                Button("关闭") { viewModel.dismissError() }
                    .controlSize(.small)
            }
            .padding(10)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if viewModel.connections.isEmpty {
            emptyState
        } else {
            searchField
            if viewModel.filteredConnections.isEmpty {
                noMatchesState
            } else {
                connectionList
            }
        }
    }

    private var searchField: some View {
        TextField("搜索连接…", text: $viewModel.searchText)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("选择一个连接开始")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack {
            Spacer()
            Text("没有匹配的连接")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionList: some View {
        List(selection: $viewModel.selectedConnectionID) {
            ForEach(viewModel.filteredConnections) { connection in
                ConnectionRowView(
                    connection: connection,
                    status: viewModel.status(for: connection),
                    onReconnect: { Task { await viewModel.reconnect(connection) } },
                    onDetails: {
                        guard case .failed(let failure) = viewModel.status(for: connection) else { return }
                        viewModel.failurePresentation = ConnectionListViewModel.FailurePresentation(
                            failure: failure,
                            connection: connection
                        )
                    }
                )
                .tag(connection.id)
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        Task { await viewModel.connect(connection) }
                    }
                )
                .contextMenu {
                    Button("编辑…") { Task { await viewModel.beginEdit(connection) } }
                    Button("复制为新连接") { Task { await viewModel.duplicate(connection) } }
                    Divider()
                    Button("删除", role: .destructive) { viewModel.requestDelete(connection) }
                    Divider()
                    Button("在 Finder 中显示配置文件") { viewModel.revealConnectionsFile() }
                }
            }
        }
        .listStyle(.inset)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                viewModel.beginCreate()
            } label: {
                Label("新建连接", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("连接") {
                guard let connection = selectedConnection else { return }
                Task { await viewModel.connect(connection) }
            }
            .disabled(selectedConnection == nil)

            Spacer()
            if viewModel.hasReconnectableSessions {
                Button("恢复全部") { Task { await viewModel.reconnectAll() } }
            }
        }
        .padding(16)
    }

    private var selectedConnection: Connection? {
        guard let selectedID = viewModel.selectedConnectionID else { return nil }
        return viewModel.connections.first { $0.id == selectedID }
    }
}

// MARK: - 列表行

/// 连接列表里的状态指示（`specs/01-connections.md` §4）。
///
/// 未连接 → 灰点；连接中 → 转圈；已连接 → 绿点；异常 → 红点；
/// 被空闲回收 / 断开（或连接失败后已断开）→ 灰点，右侧另给「点击重连」。
private struct ConnectionStatusIndicator: View {
    let status: ConnectionListViewModel.RowStatus

    var body: some View {
        Group {
            switch status {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
            case .connected:
                dot(.green)
            case .failed:
                dot(.red)
            case .notConnected, .needsReconnect:
                dot(.secondary)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func dot(_ style: Color) -> some View {
        Circle()
            .fill(style)
            .frame(width: 8, height: 8)
    }
}

private struct ConnectionRowView: View {
    let connection: Connection
    let status: ConnectionListViewModel.RowStatus
    let onReconnect: () -> Void
    let onDetails: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ConnectionStatusIndicator(status: status)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if connection.color != .none {
                        Circle()
                            .fill(connection.color.swatchColor)
                            .frame(width: 8, height: 8)
                    }
                    if connection.isReadOnly {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(connection.name)
                        .font(.body.weight(.medium))
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var summary: String {
        connection.isReadOnly ? "\(connection.summary) · 只读" : connection.summary
    }

    @ViewBuilder
    private var accessory: some View {
        switch status {
        case .connecting(let step):
            Text(step.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 8) {
                Button("查看详情") { onDetails() }
                    .controlSize(.small)
                Button("重新连接") { onReconnect() }
                    .controlSize(.small)
            }
        case .needsReconnect:
            Button("点击重连") { onReconnect() }
                .controlSize(.small)
        case .notConnected, .connected:
            EmptyView()
        }
    }
}

// MARK: - 首次连接时的密码输入

private struct ConnectionPasswordPromptView: View {

    let connection: Connection
    let onSubmit: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("输入密码")
                .font(.headline)
            Text("连接「\(connection.name)」需要密码。")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("MySQL 密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(password, remember) }
            Toggle("记住密码（保存到钥匙串）", isOn: $remember)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("连接") { onSubmit(password, remember) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
