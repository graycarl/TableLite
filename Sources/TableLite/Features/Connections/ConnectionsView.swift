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
    var presentsAsSheet: Bool

    init(presentsAsSheet: Bool = false) {
        self.presentsAsSheet = presentsAsSheet
    }

    var body: some View {
        Group {
            if let viewModel {
                ConnectionListContent(viewModel: viewModel, presentsAsSheet: presentsAsSheet)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("连接")
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
    var presentsAsSheet: Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentsAsSheet {
                sheetHeader
                Divider()
            }
            banners
            content
            Divider()
            bottomBar
        }
        .background {
            Group {
                Button("查找连接") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("编辑选中的连接") {
                    guard let connection = selectedConnection else { return }
                    Task { await viewModel.beginEdit(connection) }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(selectedConnection == nil)
            }
            .opacity(0)
            .accessibilityHidden(true)
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
        .sheet(item: $viewModel.sshSecretPrompt) { prompt in
            SSHSecretPromptView(
                request: prompt.request,
                onSubmit: { value, remember in
                    viewModel.submitSSHSecretPrompt(value, remember: remember)
                },
                onCancel: { viewModel.cancelSSHSecretPrompt() }
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
            Text("同时会删除该连接保存的密码。\n此操作不可撤销。")
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
            Text("这个连接有未提交的修改。删除连接会一并关闭它。")
        }
    }

    // MARK: 提示

    private var sheetHeader: some View {
        HStack(spacing: 8) {
            Text("连接")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭")
            .accessibilityIdentifier("connections.sheet.close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索连接…", text: $viewModel.searchText)
                .accessibilityIdentifier("connections.search")
                .textFieldStyle(.plain)
                .font(AppFont.body)
                .focused($searchFocused)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
                .accessibilityIdentifier("connections.search.clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AppRadius.m))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("还没有连接")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
            Button("新建连接") { viewModel.beginCreate() }
                .controlSize(.small)
                .accessibilityIdentifier("connections.empty.new")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("没有匹配的连接")
                .font(AppFont.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionList: some View {
        List(selection: $viewModel.selectedConnectionID) {
            ForEach(viewModel.filteredConnections) { connection in
                ConnectionRowView(
                    connection: connection,
                    status: viewModel.status(for: connection),
                    isSelected: connection.id == viewModel.selectedConnectionID,
                    isCurrent: connection.id == viewModel.activeConnectionID,
                    onReconnect: { Task { await viewModel.reconnect(connection) } },
                    onDetails: {
                        guard case .failed(let failure) = viewModel.status(for: connection) else { return }
                        viewModel.failurePresentation = ConnectionListViewModel.FailurePresentation(
                            failure: failure,
                            connection: connection
                        )
                    },
                    onEdit: { Task { await viewModel.beginEdit(connection) } },
                    onDuplicate: { Task { await viewModel.duplicate(connection) } },
                    onDelete: { viewModel.requestDelete(connection) }
                )
                .tag(connection.id)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.beginCreate()
            } label: {
                Label("新建连接", systemImage: "plus")
            }
            .buttonStyle(.subtle)
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityIdentifier("connections.new")

            Spacer()

            if viewModel.hasReconnectableSessions {
                Button("恢复全部") { Task { await viewModel.reconnectAll() } }
                    .buttonStyle(.subtle)
            }

            Button("连接") {
                guard let connection = selectedConnection else { return }
                Task { await viewModel.connect(connection) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("connections.connect")
            .disabled(selectedConnection == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
/// 被空闲回收 / 断开（或连接失败后已断开）→ 灰点，右侧另给「重新连接」。
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
    let isSelected: Bool
    let isCurrent: Bool
    let onReconnect: () -> Void
    let onDetails: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

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
                    Text(connection.name)
                        .font(AppFont.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if isCurrent {
                        badge("当前")
                    }
                    if connection.ssh.enabled {
                        badge("SSH")
                    }
                    if connection.isReadOnly {
                        HStack(spacing: 2) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                            Text("只读")
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.orange.opacity(0.4))
                        )
                    }
                }
                Text(connection.summary)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isHovering, showsHoverActions {
                HStack(spacing: 2) {
                    iconButton("pencil", id: "connections.row.edit", help: "编辑", action: onEdit)
                    iconButton("plus.square.on.square", id: "connections.row.duplicate", help: "复制为新连接", action: onDuplicate)
                    iconButton("trash", id: "connections.row.delete", help: "删除", action: onDelete)
                }
                .transition(.opacity)
            } else {
                accessory
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 54)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.12)
                : (isHovering ? Color.primary.opacity(0.04) : Color.clear),
            in: RoundedRectangle(cornerRadius: AppRadius.m)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(connection.name)
        .accessibilityValue(connection.summary)
    }

    private var showsHoverActions: Bool {
        switch status {
        case .notConnected, .connected: return true
        case .connecting, .failed, .needsReconnect: return false
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.secondary.opacity(0.3))
            )
    }

    private func iconButton(_ symbol: String, id: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
        }
        .buttonStyle(.subtle)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var accessory: some View {
        switch status {
        case .connecting(let step):
            Text(step.progressText)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 6) {
                Button("查看详情") { onDetails() }
                    .controlSize(.small)
                    .buttonStyle(.subtle)
                Button("重新连接") { onReconnect() }
                    .controlSize(.small)
            }
        case .needsReconnect:
            Button("重新连接") { onReconnect() }
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
            Toggle("记住密码", isOn: $remember)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("连接") { onSubmit(password, remember) }
                    .accessibilityIdentifier("sheet.password.connect")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - SSH 密码 / 私钥口令输入

/// 需要 SSH 密码或私钥口令时的输入框（`specs/10-ssh-tunnel.md` §3.2 / §3.3）。
///
/// 由 `ConnectionSession` 的连接流程通过 `sshSecretRequester` 弹出；勾选「记住」时
/// 由 ViewModel 写入凭据文件。界面只展示「需要」，不回显任何已保存的凭据。
private struct SSHSecretPromptView: View {

    let request: SSHSecretRequest
    let onSubmit: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var secret = ""
    @State private var remember = true

    private var isPassphrase: Bool { request.kind == .passphrase }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isPassphrase ? "输入私钥口令" : "输入 SSH 密码")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField(isPassphrase ? "私钥口令" : "SSH 密码", text: $secret)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(secret, remember) }
            Toggle(isPassphrase ? "记住口令" : "记住密码", isOn: $remember)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("连接") { onSubmit(secret, remember) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var message: String {
        if isPassphrase {
            let key = request.privateKeyPath ?? ""
            return "私钥 \(key) 有口令。连接「\(request.connectionName)」需要它。"
        }
        return "连接「\(request.connectionName)」需要 SSH 密码。"
    }
}
