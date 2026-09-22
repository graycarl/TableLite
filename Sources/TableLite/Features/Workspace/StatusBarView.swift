import SwiftUI

/// 底部状态栏（`specs/02-workspace.md` §7）。
///
/// 左侧是连接状态（点 + 名称 + 当前库 + 服务器版本 + 字符集 + 只读），
/// 右侧是标签区（行数 / 耗时等由后续 wave 填充）。
struct StatusBarView: View {

    let session: ConnectionSession
    var onEditConnection: () -> Void
    var onSwitchDatabase: () -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: 8) {
            connectionMenu
            Divider().frame(height: 12)
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

    private var connectionMenu: some View {
        Menu {
            Button("重新连接") {
                Task { try? await environment.sessionManager.reconnect(id: session.id) }
            }
            Button("断开") {
                Task { await environment.sessionManager.disconnect(id: session.id) }
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
        // 表数据标签用网格 ViewModel 的真实行数 / 耗时。
        if let viewModel = tab.content as? TableDataViewModel, let text = viewModel.statusBarText {
            return text
        }
        return WorkspaceStatusText.tabSummary(
            for: tab.kind,
            page: tab.page,
            consoleLogCount: environment.consoleLog.entries.count
        )
    }
}
