import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 标签内容区

/// 当前连接的标签内容区。
///
/// 存活策略见 `docs/tech-designs/06-ui-layer.md` §7：所有标签都留在视图树里，用
/// `ZStack` + `opacity` / `allowsHitTesting` 切换，**不用 `if`**，否则切回来会重建网格、
/// 丢滚动位置与选中状态。未连接 / 连接失败时在内容上叠加遮罩。
struct TabContentView: View {

    @ObservedObject var session: ConnectionSession
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var toasts: ToastCenter

    var body: some View {
        ZStack {
            if session.tabs.isEmpty {
                WorkspaceEmptyTabView(session: session)
            }

            ForEach(session.tabs) { tab in
                tabContent(for: tab)
                    .opacity(isActive(tab) ? 1 : 0)
                    .allowsHitTesting(isActive(tab))
                    .zIndex(isActive(tab) ? 1 : 0)
            }

            if let overlay = connectionOverlay {
                WorkspaceConnectionOverlay(state: overlay) {
                    Task { await reconnect() }
                }
                .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.12), value: session.activeTabID)
    }

    // MARK: 分发表

    /// 按标签种类分发到具体内容视图（跨文件契约见任务说明）。
    @ViewBuilder
    private func tabContent(for tab: Tab) -> some View {
        switch tab.kind {
        case .tableData:
            TableDataTabView(session: session, tab: tab, environment: env)
        case .tableStructure:
            TableStructureTabView(session: session, tab: tab, environment: env)
        case .objectDefinition:
            ObjectDefinitionTabView(session: session, tab: tab, environment: env)
        case .query:
            QueryTabView(session: session, tab: tab, environment: env)
        case .history:
            HistoryTabView(session: session, tab: tab, environment: env)
        case .consoleLog:
            ConsoleLogTabView(session: session, tab: tab, environment: env)
        }
    }

    private func isActive(_ tab: Tab) -> Bool {
        session.activeTabID == tab.id
    }

    // MARK: 连接遮罩

    private var connectionOverlay: WorkspaceConnectionOverlayState? {
        switch session.state {
        case .connected:
            return nil
        case .connecting(let step):
            return .connecting(step)
        case .disconnected:
            return .disconnected
        case .failed(let error):
            return .failed(error)
        }
    }

    private func reconnect() async {
        do {
            try await env.sessionManager.reconnect(id: session.id)
            toasts.show("已重新连接")
        } catch {
            logger.error("重新连接失败：\(String(describing: error), privacy: .public)")
            toasts.show((error as? MySQLError)?.title ?? "重新连接失败")
        }
    }
}

// MARK: - 连接遮罩

enum WorkspaceConnectionOverlayState {
    case connecting(ConnectStep)
    case disconnected
    case failed(MySQLError)
}

struct WorkspaceConnectionOverlay: View {

    let state: WorkspaceConnectionOverlayState
    let onReconnect: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                switch state {
                case .connecting(let step):
                    ProgressView()
                    Text("正在连接…（\(step.displayName)）")
                        .foregroundStyle(.secondary)
                case .disconnected:
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("已断开").font(.headline)
                    Button("重新连接", action: onReconnect)
                case .failed(let error):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error.title).font(.headline)
                    if let server = error.serverError {
                        Text(server.formatted)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                        if let hint = server.chineseHint {
                            Text(hint).foregroundStyle(.secondary)
                        }
                    }
                    Button("重新连接", action: onReconnect)
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
        }
    }
}

// MARK: - 无标签空状态

private struct WorkspaceEmptyTabView: View {

    @ObservedObject var session: ConnectionSession

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(session.state.isConnected ? "打开一个表，或新建查询开始" : "连接已断开")
                .foregroundStyle(.secondary)
            if session.state.isConnected {
                Button("新建查询") { session.newQueryTab() }
                    .keyboardShortcut("t", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 过期提示条

/// 结构 / 对象定义「可能过期」的黄色提示条（`specs/12-feedback.md` §7）。
struct WorkspaceStaleBanner: View {

    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("内容可能已过期")
                .font(.callout)
            Spacer()
            Button("刷新", action: onRefresh)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.15))
    }
}

// MARK: - 加载失败

/// 只读内容加载失败的统一展示（标题 + 原始错误 + 重试）。
struct WorkspaceLoadErrorView: View {

    let error: MySQLError
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(error.title).font(.headline)
            if let server = error.serverError {
                Text(server.formatted)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                if let hint = server.chineseHint {
                    Text(hint).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let retry {
                Button("重试", action: retry)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 表结构占位视图（Wave 5 会用同名文件覆盖）

/// ⚠️ 临时占位。真正的表结构视图由后续 wave 提供（列 / 索引 / 外键 / 触发器 / 建表语句），
/// 由后续 wave 用同名文件覆盖本定义。这里只为不阻塞集成，展示占位文案与过期提示条。
struct TableStructureTabView: View {

    let session: ConnectionSession
    let tab: Tab
    let environment: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            if tab.isStale {
                WorkspaceStaleBanner { tab.isStale = false }
            }
            VStack(spacing: 10) {
                Image(systemName: "tablecells")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("表结构视图（即将实现）")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
