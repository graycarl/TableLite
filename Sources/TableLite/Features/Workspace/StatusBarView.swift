import SwiftUI

/// 底部状态栏（`specs/02-workspace.md` §7）。
///
/// 左侧是连接状态（点 + 名称 + 当前库 + 服务器版本 + 字符集 + 只读），
/// 有未提交改动时插入橙色提示条；右侧是标签区。
struct StatusBarView: View {

    let session: ConnectionSession
    var onEditConnection: () -> Void
    var onSwitchDatabase: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(PendingChangesCoordinator.self) private var pendingChanges

    var body: some View {
        HStack(spacing: 8) {
            connectionMenu
            Divider().frame(height: 12)
            if let viewModel = activeTableViewModel, viewModel.pendingCount > 0 {
                pendingStrip(viewModel)
                Divider().frame(height: 12)
            }
            Spacer(minLength: 12)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var activeTableViewModel: TableDataViewModel? {
        session.activeTab?.content as? TableDataViewModel
    }

    /// 未提交改动的橙色提示条（`specs/02-workspace.md` §7）。
    private func pendingStrip(_ viewModel: TableDataViewModel) -> some View {
        HStack(spacing: 6) {
            Circle().fill(.orange).frame(width: 6, height: 6)
            Text(viewModel.pendingStore.statusText ?? "")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(1)
            Button("查看详情") { viewModel.presentPreview() }
                .controlSize(.mini)
        }
    }

    private var connectionMenu: some View {
        Menu {
            Button("重新连接") {
                Task { try? await environment.sessionManager.reconnect(id: session.id) }
            }
            Button("断开") {
                Task {
                    if await pendingChanges.resolveLeave(session: session) {
                        await environment.sessionManager.disconnect(id: session.id)
                    }
                }
            }
            Divider()
            Button("编辑连接…") { onEditConnection() }
            Button("切换数据库…") { onSwitchDatabase() }
            Divider()
            // 服务器变量面板属于后续 wave。
            Button("显示服务器变量…") { }
                .disabled(true)
        } label: {
            HStack(spacing: 6) {
                SessionStatusDot(state: session.state)
                Text(baseLine)
                    .font(.callout)
                    .lineLimit(1)
                if session.isReadOnly {
                    Text("只读")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("连接操作")
    }

    private var baseLine: String {
        WorkspaceStatusText.connectionLine(
            connection: session.connection,
            state: session.state,
            database: session.selectedDatabase,
            serverInfo: session.serverInfo,
            isReadOnly: false
        )
    }

    private var summary: String {
        guard let tab = session.activeTab else { return "" }
        if let viewModel = tab.content as? TableDataViewModel {
            if viewModel.isCommitting {
                return "正在提交 \(viewModel.commitCompleted)/\(viewModel.commitTotal)…"
            }
            if let reason = viewModel.uneditableStatusText {
                return reason
            }
            if let text = viewModel.statusBarText {
                return text
            }
        }
        return WorkspaceStatusText.tabSummary(
            for: tab.kind,
            page: tab.page,
            consoleLogCount: environment.consoleLog.entries.count
        )
    }
}
