import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 状态栏

/// 底部状态栏：左侧是当前标签的关键信息（未提交时最左插一条橙色提示条），
/// 右侧是标签相关操作与连接状态。见 `specs/02-workspace.md` §7。
struct StatusBarView: View {

    @ObservedObject var session: ConnectionSession
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HStack(spacing: 10) {
            if let tab = session.activeTab {
                leftStatus(tab)
                Spacer(minLength: 8)
                rightStatus(tab)
                Divider().frame(height: 14)
            } else {
                Spacer(minLength: 0)
            }
            ConnectionStatusMenu(session: session)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    @ViewBuilder
    private func leftStatus(_ tab: Tab) -> some View {
        switch tab.kind {
        case .tableData:
            TableDataStatusLeft(tab: tab)
        case .query:
            QueryStatusLeft(tab: tab)
        case .tableStructure:
            StructureStatusLeft(tab: tab)
        case .objectDefinition:
            Text(tab.isStale ? "定义可能已过期" : "只读定义")
                .foregroundStyle(.secondary)
        case .history:
            HistoryStatusLeft()
        case .consoleLog:
            ConsoleStatusLeft(store: env.consoleLog)
        }
    }

    @ViewBuilder
    private func rightStatus(_ tab: Tab) -> some View {
        switch tab.kind {
        case .tableData:
            TableDataStatusRight(tab: tab)
        case .query:
            QueryStatusRight(tab: tab)
        default:
            EmptyView()
        }
    }
}

// MARK: - 表数据

private struct TableDataStatusLeft: View {

    @ObservedObject var tab: Tab

    var body: some View {
        if let viewModel = tab.tableData as? TableDataViewModel {
            TableDataStatusContent(viewModel: viewModel)
        } else {
            Text("表数据").foregroundStyle(.secondary)
        }
    }
}

private struct TableDataStatusContent: View {

    @ObservedObject var viewModel: TableDataViewModel
    @State private var showingPreview = false

    var body: some View {
        HStack(spacing: 10) {
            if !viewModel.pending.isEmpty {
                PendingChangesBar(viewModel: viewModel, showingPreview: $showingPreview)
            }
            Text(statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .sheet(isPresented: $showingPreview) {
            WorkspacePendingSQLSheet(viewModel: viewModel, isPresented: $showingPreview)
        }
    }

    private var statusText: String {
        "\(viewModel.rowRangeText) / \(viewModel.rowCountText) · \(viewModel.pageNumberText) · \(viewModel.pageSizeText)"
    }
}

private struct PendingChangesBar: View {

    @ObservedObject var viewModel: TableDataViewModel
    @Binding var showingPreview: Bool

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 3, height: 16)
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
            Text("有 \(viewModel.pendingStats.total) 处未提交的修改（\(viewModel.pendingStats.summary)）")
                .foregroundStyle(.orange)
                .lineLimit(1)
            Button("查看详情") { showingPreview = true }
                .buttonStyle(.link)
        }
    }
}

private struct TableDataStatusRight: View {

    @ObservedObject var tab: Tab
    @EnvironmentObject private var toasts: ToastCenter

    private var hasViewModel: Bool {
        tab.tableData is TableDataViewModel
    }

    var body: some View {
        if hasViewModel {
            HStack(spacing: 8) {
                // TODO(Wave 5)：过滤面板与列面板由数据浏览视图提供，这里先只给占位入口。
                Button("筛选") { notImplemented("筛选") }
                Button("列") { notImplemented("列") }
                Button("导出…") { notImplemented("导出") }
            }
            .buttonStyle(.link)
        }
    }

    private func notImplemented(_ feature: String) {
        toasts.show("\(feature)功能即将实现")
    }
}

// MARK: - 查询编辑器

private struct QueryStatusLeft: View {

    @ObservedObject var tab: Tab

    var body: some View {
        if let viewModel = tab.query as? QueryTabViewModel {
            QueryStatusContent(viewModel: viewModel)
        } else {
            Text("查询").foregroundStyle(.secondary)
        }
    }
}

private struct QueryStatusContent: View {

    @ObservedObject var viewModel: QueryTabViewModel

    var body: some View {
        Text(viewModel.statusSummary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct QueryStatusRight: View {

    @ObservedObject var tab: Tab

    var body: some View {
        if let viewModel = tab.query as? QueryTabViewModel {
            QueryStopButton(viewModel: viewModel)
        }
    }
}

private struct QueryStopButton: View {

    @ObservedObject var viewModel: QueryTabViewModel

    var body: some View {
        if viewModel.isExecuting {
            Button("停止") { viewModel.stop() }
                .help("停止执行（⌘.）")
        }
    }
}

// MARK: - 表结构

private struct StructureStatusLeft: View {

    @ObservedObject var tab: Tab

    var body: some View {
        if let viewModel = tab.tableStructure as? TableStructureViewModel {
            StructureStatusContent(viewModel: viewModel)
        } else {
            Text("表结构").foregroundStyle(.secondary)
        }
    }
}

private struct StructureStatusContent: View {

    @ObservedObject var viewModel: TableStructureViewModel

    var body: some View {
        Text(viewModel.statusSummary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - 查询历史 / Console Log

private struct HistoryStatusLeft: View {

    @EnvironmentObject private var env: AppEnvironment
    @State private var count: Int?

    var body: some View {
        Text(count.map { "\($0) 条记录" } ?? "查询历史")
            .foregroundStyle(.secondary)
            .task { count = try? env.history.count() }
    }
}

private struct ConsoleStatusLeft: View {

    @ObservedObject var store: ConsoleLogStore

    var body: some View {
        Text("\(store.entries.count) 条记录")
            .foregroundStyle(.secondary)
    }
}

// MARK: - 连接状态

private struct ConnectionStatusMenu: View {

    @ObservedObject var session: ConnectionSession
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var toasts: ToastCenter

    var body: some View {
        Menu {
            Button("重新连接") { reconnect() }
            Button("断开") { disconnect() }
            Divider()
            Button("编辑连接…") { toasts.show("连接编辑界面即将实现") }
            Menu("切换数据库…") {
                if session.databases.isEmpty {
                    Text("没有可访问的数据库")
                } else {
                    ForEach(session.databases, id: \.self) { database in
                        Button(database) { switchDatabase(database) }
                    }
                }
            }
            Button("显示服务器变量…") { toasts.show("服务器变量界面即将实现") }
        } label: {
            HStack(spacing: 6) {
                WorkspaceStatusDot(state: session.state)
                Text(statusText)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statusText: String {
        var parts: [String] = []
        parts.append(session.displayName.isEmpty ? session.connection.mysql.host : session.displayName)
        if let database = session.selectedDatabase, !database.isEmpty {
            parts.append(database)
        }
        if let version = session.serverVersion {
            parts.append("MySQL \(version)")
        }
        if let charset = session.charset {
            parts.append(charset)
        }
        if session.isReadOnly {
            parts.append("只读")
        }
        return parts.joined(separator: " · ")
    }

    private func reconnect() {
        Task {
            do {
                try await env.sessionManager.reconnect(id: session.id)
                toasts.show("已重新连接")
            } catch {
                logger.error("重新连接失败：\(String(describing: error), privacy: .public)")
                toasts.show((error as? MySQLError)?.title ?? "重新连接失败")
            }
        }
    }

    private func disconnect() {
        Task {
            await env.sessionManager.disconnect(id: session.id)
            toasts.show("连接已断开")
        }
    }

    private func switchDatabase(_ database: String) {
        session.selectedDatabase = database
        Task { await session.refreshObjects() }
    }
}
