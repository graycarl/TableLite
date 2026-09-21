import AppKit
import SwiftUI

// MARK: - 工作区菜单动作
//
// 工作区里的大部分操作（新建查询、提交、切换标签…）只有当前标签的 ViewModel 知道怎么做，
// 因此通过 `@FocusedValue` 从焦点视图上报。菜单结构按 `specs/02-workspace.md` §8 §9 固定声明；
// 尚未接上的动作显示为禁用，留给后续 wave 装配。

struct WorkspaceCommandActions {
    var newQuery: (() -> Void)?
    var closeTab: (() -> Void)?
    var previousTab: (() -> Void)?
    var nextTab: (() -> Void)?
    var refresh: (() -> Void)?
    var commit: (() -> Void)?
    var previewSQL: (() -> Void)?
    var discard: (() -> Void)?
    var cancelQuery: (() -> Void)?
    var switchDatabase: (() -> Void)?
    var toggleSidebar: (() -> Void)?
    var toggleRowInspector: (() -> Void)?
    var toggleConsoleLog: (() -> Void)?
    var toggleFilter: (() -> Void)?
    var toggleColumnFilter: (() -> Void)?
    var insertRow: (() -> Void)?
    var duplicateRow: (() -> Void)?
    var deleteRow: (() -> Void)?
    var quickLook: (() -> Void)?
    var toggleComment: (() -> Void)?
    var indent: (() -> Void)?
    var outdent: (() -> Void)?
    var find: (() -> Void)?
    var openScript: (() -> Void)?
    var saveScriptAs: (() -> Void)?
    var importCSV: (() -> Void)?
    var exportData: (() -> Void)?
}

private struct WorkspaceCommandActionsKey: FocusedValueKey {
    typealias Value = WorkspaceCommandActions
}

extension FocusedValues {
    var tableLiteWorkspaceActions: WorkspaceCommandActions? {
        get { self[WorkspaceCommandActionsKey.self] }
        set { self[WorkspaceCommandActionsKey.self] = newValue }
    }
}

// MARK: - 应用入口

@main
struct TableLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var env: AppEnvironment
    @StateObject private var toasts = ToastCenter()
    @StateObject private var sheets = ConnectionSheets()

    init() {
        // `--smoke` 时跑完 C shim 的端到端验证就直接退出，不启动 GUI。
        // 见 Sources/TableLite/Core/MySQL/SmokeRunner.swift。
        SmokeRunner.runIfRequested()

        // `AppEnvironment.live()` 内部已经 `restoreIfNeeded()` 并 `startIdleReaper()`，
        // 这里不再重复调用，避免恢复逻辑并发跑两遍。
        _env = StateObject(wrappedValue: AppEnvironment.live())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environmentObject(toasts)
                .environmentObject(sheets)
                .toastOverlay(toasts)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appDelegate.environment = env }
        }
        .windowResizability(.contentMinSize)
        .commands {
            TableLiteCommands(env: env, sheets: sheets)
        }

        Settings {
            PreferencesView()
                .environmentObject(env)
                .environmentObject(toasts)
        }
    }
}

// MARK: - 根视图

/// 根视图：未连接任何会话时显示连接列表，否则显示工作区。
///
/// `WorkspaceView` / `ConnectionsView` 自己从 `@EnvironmentObject var env` 取状态
/// （契约见 `docs/tech-designs/06-ui-layer.md` §2）。
private struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var sheets: ConnectionSheets

    var body: some View {
        RootContent(sessionManager: env.sessionManager)
            .sheet(item: $sheets.target) { target in
                ConnectionFormView(env: env, target: target)
                    .environmentObject(env)
                    .environmentObject(toasts)
                    .environmentObject(sheets)
            }
    }
}

/// 单独观察 `SessionManager` 的 `@Published` 变化（`AppEnvironment` 不转发它的 objectWillChange）。
private struct RootContent: View {
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        if sessionManager.activeSession == nil {
            ConnectionsView()
        } else {
            WorkspaceView()
        }
    }
}

// MARK: - 菜单

struct TableLiteCommands: Commands {
    let env: AppEnvironment
    let sheets: ConnectionSheets

    @FocusedValue(\.tableLiteWorkspaceActions) private var actions

    var body: some Commands {
        // 单窗口应用：`⌘N` 绑定「新建连接」，不要「新建窗口」。
        CommandGroup(replacing: .newItem) {
            Button("新建连接") {
                sheets.newConnection(preferences: env.preferences)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(after: .newItem) {
            Button("新建查询") { actions?.newQuery?() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions?.newQuery == nil)

            Button("关闭标签") { actions?.closeTab?() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(actions?.closeTab == nil)

            Divider()

            Button("打开脚本…") { actions?.openScript?() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions?.openScript == nil)

            Button("脚本另存为…") { actions?.saveScriptAs?() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions?.saveScriptAs == nil)

            Divider()

            Button("导入 CSV…") { actions?.importCSV?() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions?.importCSV == nil)

            Button("导出…") { actions?.exportData?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.exportData == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("注释切换") { actions?.toggleComment?() }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(actions?.toggleComment == nil)
            Button("缩进") { actions?.indent?() }
                .disabled(actions?.indent == nil)
            Button("反缩进") { actions?.outdent?() }
                .disabled(actions?.outdent == nil)
            Divider()
            Button("查找") { actions?.find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.find == nil)
        }

        CommandMenu("连接") {
            Button("重新连接") { reconnectActiveSession() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(env.sessionManager.activeSession == nil)

            Button("断开连接") { disconnectActiveSession() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(env.sessionManager.activeSession == nil)

            Button("切换数据库…") { actions?.switchDatabase?() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(actions?.switchDatabase == nil)

            Divider()

            Button("刷新") { actions?.refresh?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.refresh == nil)

            Button("提交修改") { actions?.commit?() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions?.commit == nil)

            Button("预览 SQL") { actions?.previewSQL?() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(actions?.previewSQL == nil)

            Button("放弃修改") { actions?.discard?() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(actions?.discard == nil)

            Button("取消查询") { actions?.cancelQuery?() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.cancelQuery == nil)

            Divider()

            Toggle("只读模式", isOn: readOnlyBinding)
        }

        CommandMenu("视图") {
            Button("显示 / 隐藏左侧栏") { actions?.toggleSidebar?() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(actions?.toggleSidebar == nil)

            Button("显示 / 隐藏右侧字段栏") { actions?.toggleRowInspector?() }
                .disabled(actions?.toggleRowInspector == nil)

            Button("显示 / 隐藏 Console Log") { actions?.toggleConsoleLog?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(actions?.toggleConsoleLog == nil)

            Divider()

            Button("上一个标签") { actions?.previousTab?() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.previousTab == nil)

            Button("下一个标签") { actions?.nextTab?() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions?.nextTab == nil)
        }

        CommandGroup(replacing: .help) {
            Button("使用说明") { openManual() }
            Button("打开数据目录") { openDataDirectory() }
        }
    }

    // MARK: 动作

    private var readOnlyBinding: Binding<Bool> {
        Binding(
            get: { env.sessionManager.activeSession?.isReadOnly ?? false },
            set: { env.sessionManager.activeSession?.setReadOnly($0) }
        )
    }

    private func reconnectActiveSession() {
        guard let id = env.sessionManager.activeSessionID else { return }
        Task { try? await env.sessionManager.reconnect(id: id) }
    }

    private func disconnectActiveSession() {
        guard let id = env.sessionManager.activeSessionID else { return }
        Task { await env.sessionManager.disconnect(id: id) }
    }

    private func openDataDirectory() {
        let url = env.fileSystem.applicationSupportDirectory
        try? env.fileSystem.ensureDirectory(at: url)
        NSWorkspace.shared.open(url)
    }

    private func openManual() {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "manual") {
            NSWorkspace.shared.open(url)
        }
    }
}
