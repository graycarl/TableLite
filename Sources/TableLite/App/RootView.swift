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
            PreferencesView()
        }
        // Console Log 的容量 / 落盘偏好改了立刻生效（`specs/11-preferences.md` §7）。
        .onChange(of: environment.preferences.consoleLogCapacity) { _, _ in
            environment.syncConsoleLogSettings()
        }
        .onChange(of: environment.preferences.consoleLogWriteToFile) { _, _ in
            environment.syncConsoleLogSettings()
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
            showHelp: { openManual() },
            openDataDirectory: {
                NSWorkspace.shared.open(environment.layout.rootDirectory)
            }
        )
    }

    /// 「帮助 → 使用说明」打开已发布的图形化说明书（`12-build-and-deps.md` §5.1）。
    private func openManual() {
        guard let url = URL(string: "https://graycarl.github.io/TableLite/") else { return }
        NSWorkspace.shared.open(url)
    }
}
