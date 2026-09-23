import SwiftUI

/// 底部状态栏（`specs/02-workspace.md` §7）。
///
/// 左侧是连接状态（点 + 名称 + 当前库 + 服务器版本 + 字符集 + 只读），
/// 有未提交改动时插入橙色提示条；右侧是标签区。
struct StatusBarView: View {

    let session: ConnectionSession
    var onEditConnection: () -> Void
    var onSwitchDatabase: () -> Void
    /// 短暂状态栏提示（如进入只读连接，`specs/09-readonly-mode.md` §5）。非空时整条状态栏只显示它。
    var transientMessage: String?
    /// 正在进行的导出进度（`specs/12-feedback.md` §2）：`正在导出… 已写入 N 行（X MB）`。
    var exportProgress: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(PendingChangesCoordinator.self) private var pendingChanges

    var body: some View {
        HStack(spacing: 8) {
            if let transientMessage {
                Text(transientMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else if let exportProgress {
                // 导出在后台进行时，状态栏显示进度（`specs/12-feedback.md` §2）。
                ProgressView()
                    .controlSize(.small)
                Text(exportProgress)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                connectionMenu
                Divider().frame(height: 12)
                if let viewModel = activeTableViewModel, viewModel.pendingCount > 0 {
                    pendingStrip(viewModel)
                    Divider().frame(height: 12)
                }
                Spacer(minLength: 12)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
                Text(baseLineParts.body)
                    .font(.callout)
                    .lineLimit(1)
                if let marker = baseLineParts.readOnlyMarker {
                    // 只读段用醒目颜色单独渲染（`specs/09-readonly-mode.md` §3）。
                    Text(marker)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(connectionHelp)
    }

    /// 状态栏连接区的悬停详情。
    ///
    /// 启用了 SSH 隧道时带上本地转发端口（`specs/10-ssh-tunnel.md` §4：隧道信息
    /// 只在悬停详情里显示，主界面正文不显示本地端口）。
    private var connectionHelp: String {
        guard let endpoint = session.tunnelEndpoint else { return "连接操作" }
        let tunnelLine = WorkspaceStatusText.tunnelDetailLine(host: endpoint.host, port: endpoint.port)
        return "连接操作\n\(tunnelLine)"
    }

    private var baseLineParts: WorkspaceStatusText.ConnectionLineParts {
        WorkspaceStatusText.connectionLineParts(
            connection: session.connection,
            state: session.state,
            database: session.selectedDatabase,
            serverInfo: session.serverInfo,
            isReadOnly: session.isReadOnly
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
            // 行数摘要与筛选 / 列 / 导出入口已移到网格底部条（`specs/03-data-browsing.md` §2）。
            return ""
        }
        if let editor = tab.content as? QueryEditorViewModel {
            if editor.isRunning {
                return "正在执行…"
            }
            return WorkspaceStatusText.querySummary(
                executedStatementCount: editor.executedStatementCount,
                elapsedMilliseconds: editor.elapsedMilliseconds,
                totalReturnedRows: editor.totalReturnedRows
            ) ?? "等待执行"
        }
        // 表结构标签显示概况（`specs/07-schema-view.md` §5）；对象定义标签保持占位文案。
        if let structure = tab.content as? TableStructureViewModel,
           structure.isTableStructureTab,
           let statusSummary = structure.statusSummary {
            return statusSummary
        }
        // 表数据标签未装配 ViewModel 时不再回退显示「最多 N 行」，底部条负责行数。
        if case .tableData = tab.kind { return "" }
        return WorkspaceStatusText.tabSummary(
            for: tab.kind,
            rowLimit: tab.rowLimit,
            consoleLogCount: environment.consoleLog.entries.count
        )
    }
}
