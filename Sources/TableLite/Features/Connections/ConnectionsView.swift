import AppKit
import SwiftUI
import os

// MARK: - 连接表单协调器
//
// 表单在根视图上用 `.sheet(item:)` 呈现一次，这样无论当前是连接列表还是工作区，
// `⌘N` 都能打开「新建连接」。见 `specs/02-workspace.md` §8。

@MainActor
final class ConnectionSheets: ObservableObject {

    struct Target: Identifiable {
        let id = UUID()
        var connection: Connection
        var isNew: Bool
    }

    @Published var target: Target?

    /// 新建连接。默认值来自偏好（`specs/11-preferences.md` §2）。
    func newConnection(preferences: PreferencesStore) {
        var connection = Connection()
        connection.mysql.queryTimeout = preferences.defaultQueryTimeout
        connection.mysql.keepAlive = preferences.defaultKeepAlive
        connection.mysql.keepAliveInterval = preferences.keepAliveInterval
        target = Target(connection: connection, isNew: true)
    }

    func edit(_ connection: Connection) {
        target = Target(connection: connection, isNew: false)
    }

    /// 复制为新连接：新 id、名字加后缀，密码不复制（凭据按连接 id 存 Keychain）。
    func duplicate(_ connection: Connection) {
        var copy = connection
        copy.id = UUID()
        copy.name = connection.name + " 副本"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        target = Target(connection: copy, isNew: true)
    }
}

// MARK: - 连接失败上下文

/// 连接失败时用于错误面板的信息。见 `specs/12-feedback.md` §5。
struct ConnectionFailureInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var connection: Connection
    var password: String?

    static func make(error: Error, connection: Connection, password: String?) -> ConnectionFailureInfo {
        guard let mysqlError = error as? MySQLError else {
            return ConnectionFailureInfo(
                title: "连接失败",
                message: "\(String(describing: error))\n\n尚未连接，可以重试或编辑连接配置。",
                connection: connection,
                password: password
            )
        }

        var text = ""
        if let serverError = mysqlError.serverError {
            text = serverError.formatted
            if let hint = serverError.chineseHint {
                text += "\n\n\(hint)"
            }
        } else if case .connect(let step, let message, let detail) = mysqlError {
            text = "发生在：\(step.displayName)\n\n\(message)"
            if let detail, !detail.isEmpty {
                text += "\n\(detail)"
            }
        } else {
            text = mysqlError.title
        }
        text += "\n\n尚未连接，可以重试或编辑连接配置。"

        return ConnectionFailureInfo(title: mysqlError.title,
                                     message: text,
                                     connection: connection,
                                     password: password)
    }
}

// MARK: - 连接颜色

/// 连接颜色圆点的展示色。默认「无色」显示为浅灰。
func connectionDotColor(_ color: ConnectionColor) -> Color {
    switch color {
    case .none: return Color.secondary.opacity(0.35)
    case .red: return .red
    case .orange: return .orange
    case .yellow: return .yellow
    case .green: return .green
    case .blue: return .blue
    case .purple: return .purple
    case .gray: return .gray
    }
}

// MARK: - ConnectionsView

/// 连接列表。见 `specs/01-connections.md` §1。
struct ConnectionsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var sheets: ConnectionSheets

    @State private var searchText = ""
    @State private var selection: UUID?
    @State private var pendingDelete: Connection?
    @State private var passwordPrompt: Connection?
    @State private var connectFailure: ConnectionFailureInfo?
    @State private var openError: String?

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    private var allConnections: [Connection] { env.connections.connections }

    private var filteredConnections: [Connection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allConnections }
        return allConnections.filter { connection in
            connection.name.localizedCaseInsensitiveContains(query)
                || connection.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("确定要删除连接「\(pendingDelete?.name ?? "")」吗？",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let connection = pendingDelete { delete(connection) }
                pendingDelete = nil
            }
        } message: {
            Text("同时会删除保存在系统钥匙串里的密码。\n此操作不可撤销。")
        }
        .alert("连接失败",
               isPresented: Binding(get: { connectFailure != nil },
                                    set: { if !$0 { connectFailure = nil } }),
               presenting: connectFailure) { info in
            Button("重试") {
                let retry = info
                connectFailure = nil
                performConnect(retry.connection, password: retry.password)
            }
            Button("关闭", role: .cancel) { connectFailure = nil }
        } message: { info in
            Text(info.message)
        }
        .alert("无法读取连接配置",
               isPresented: Binding(get: { openError != nil },
                                    set: { if !$0 { openError = nil } })) {
            Button("关闭", role: .cancel) { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .sheet(item: $passwordPrompt) { connection in
            PasswordPromptView(connection: connection) { password, remember in
                savePromptedPassword(password, remember: remember, connection: connection)
                passwordPrompt = nil
                performConnect(connection, password: password.isEmpty ? nil : password)
            }
        }
    }

    // MARK: 子视图

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TableLite")
                .font(.largeTitle.bold())
            Text("macOS 原生 MySQL 客户端")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索连接…", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if allConnections.isEmpty {
            emptyState
        } else if filteredConnections.isEmpty {
            VStack {
                Spacer()
                Text("没有匹配的连接")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(filteredConnections) { connection in
                    ConnectionRowView(connection: connection,
                                      state: env.sessionManager.session(id: connection.id)?.state ?? .disconnected)
                        .tag(connection.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { activate(connection) }
                        .contextMenu {
                            Button("编辑…") { sheets.edit(connection) }
                            Button("复制为新连接") { sheets.duplicate(connection) }
                            Button("删除") { pendingDelete = connection }
                            Divider()
                            Button("在 Finder 中显示配置文件") { revealConfigFile() }
                        }
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("选择一个连接开始")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                sheets.newConnection(preferences: env.preferences)
            } label: {
                Label("新建连接", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    // MARK: 动作

    private func activate(_ connection: Connection) {
        let key = CredentialKey(kind: .mysqlPassword, connectionID: connection.id)
        if let saved = try? env.credentials.retrieve(key) {
            performConnect(connection, password: saved)
        } else {
            passwordPrompt = connection
        }
    }

    private func performConnect(_ connection: Connection, password: String?) {
        Task {
            do {
                try await env.sessionManager.connect(connection, password: password)
            } catch {
                logger.error("连接失败：\(String(describing: error), privacy: .public)")
                connectFailure = ConnectionFailureInfo.make(error: error,
                                                            connection: connection,
                                                            password: password)
            }
        }
    }

    private func savePromptedPassword(_ password: String, remember: Bool, connection: Connection) {
        guard remember else { return }
        let key = CredentialKey(kind: .mysqlPassword, connectionID: connection.id)
        do {
            if password.isEmpty {
                try env.credentials.delete(key)
            } else {
                try env.credentials.store(password, for: key)
            }
        } catch {
            logger.error("钥匙串写入失败：\(String(describing: error), privacy: .public)")
        }
    }

    private func delete(_ connection: Connection) {
        Task {
            if let session = env.sessionManager.session(id: connection.id) {
                await session.close()
            }
            do {
                try env.connections.remove(id: connection.id)
            } catch {
                logger.error("删除连接失败：\(String(describing: error), privacy: .public)")
                openError = "删除连接失败：\(error.localizedDescription)"
                return
            }
            do {
                try env.credentials.deleteAll(connectionID: connection.id)
            } catch {
                logger.error("删除钥匙串条目失败：\(String(describing: error), privacy: .public)")
            }
            env.tableState.removeAll(connectionID: connection.id)
            toasts.show("已删除连接「\(connection.name)」")
        }
    }

    private func revealConfigFile() {
        NSWorkspace.shared.activateFileViewerSelecting([env.connections.fileURL])
    }
}

// MARK: - 行

private struct ConnectionRowView: View {
    let connection: Connection
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            ConnectionStatusDot(state: state)
            Circle()
                .fill(connectionDotColor(connection.color))
                .frame(width: 8, height: 8)
            if connection.readOnly {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .fontWeight(.medium)
                Text(connection.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct ConnectionStatusDot: View {
    let state: ConnectionState

    var body: some View {
        switch state {
        case .disconnected:
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 8, height: 8)
        case .connected:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        }
    }
}

// MARK: - 密码输入

/// 首次连接时没有已保存的密码。见 `specs/01-connections.md` §2。
private struct PasswordPromptView: View {
    let connection: Connection
    let onSubmit: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("输入「\(connection.name)」的密码")
                .font(.headline)
            Text(connection.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("密码", text: $password)
            Toggle("记住密码（保存到钥匙串）", isOn: $remember)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("连接") {
                    onSubmit(password, remember)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
