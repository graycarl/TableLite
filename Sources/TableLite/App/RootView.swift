import SwiftUI
import AppKit

/// 应用根视图：按「有没有活动会话」在连接列表与工作区之间分流
/// （`specs/02-workspace.md` §1、§10；`specs/01-connections.md` §7）。
///
/// - 无活动会话 → `ConnectionsView`（连接列表；零连接时显示「选择一个连接开始」）；
/// - 有活动会话 → `WorkspaceView(session:)`；切换连接由 `SessionManager.activeSessionID`
///   驱动，**不关闭**其它会话。
///
/// 同时通过 `.focusedSceneValue(\.appActions, ...)` 向菜单栏暴露应用级动作。
struct RootView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var showConnectionList = false
    @State private var showPreferences = false
    @State private var showHelp = false

    var body: some View {
        Group {
            if let session = environment.sessionManager.activeSession {
                WorkspaceView(session: session)
                    // 切换连接时重置工作区的本地界面状态（搜索框、标签惰性创建等）。
                    .id(session.id)
            } else {
                ConnectionsView()
            }
        }
        .focusedSceneValue(\.appActions, appActions)
        .background(
            WindowConfigurator(autosaveName: WorkspaceStateStore.windowFrameAutosaveName)
                .frame(width: 0, height: 0)
        )
        .sheet(isPresented: $showConnectionList) {
            ConnectionsView()
        }
        // 连接成功后主区已切到工作区，顺手关掉连接管理 sheet
        .onChange(of: environment.sessionManager.activeSessionID) { _, newValue in
            if newValue != nil { showConnectionList = false }
        }
        .sheet(isPresented: $showPreferences) {
            preferencesPlaceholder
        }
        .sheet(isPresented: $showHelp) {
            helpPlaceholder
        }
    }

    private var appActions: AppActions {
        var newConnection: (@MainActor () -> Void)?
        // 没有会话时，连接列表自己的 `+ 新建连接`（⌘N）负责打开表单。
        if environment.sessionManager.activeSession != nil {
            newConnection = { showConnectionList = true }
        }
        return AppActions(
            newConnection: newConnection,
            openPreferences: { showPreferences = true },
            showHelp: { showHelp = true },
            openDataDirectory: {
                NSWorkspace.shared.open(environment.layout.rootDirectory)
            }
        )
    }

    // 偏好设置属于 P11，本阶段给一个明确占位。
    private var preferencesPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("偏好设置")
                .font(.title3)
            Text("偏好设置面板待 P11 实现")
                .foregroundStyle(.secondary)
            Button("关闭") { showPreferences = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 360, height: 220)
    }

    private var helpPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "book")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("使用说明")
                .font(.title3)
            Text("图形化使用说明书见仓库 `manual/` 目录")
                .foregroundStyle(.secondary)
            Button("关闭") { showHelp = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 360, height: 220)
    }
}
