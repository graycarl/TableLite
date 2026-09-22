import SwiftUI
import AppKit

// MARK: - App 级动作

/// 与工作区无关的应用级动作（新建连接、偏好设置、帮助）。
///
/// 由 `RootView` 通过 `.focusedSceneValue` 提供，菜单栏的 `TableLiteCommands` 读取。
/// `newConnection` 为 nil 时菜单项禁用：没有会话时连接列表自己处理 `⌘N`。
struct AppActions {
    var newConnection: (@MainActor () -> Void)?
    var openPreferences: @MainActor () -> Void
    var showHelp: @MainActor () -> Void
    var openDataDirectory: @MainActor () -> Void
}

private struct AppActionsKey: FocusedValueKey {
    typealias Value = AppActions
}

// MARK: - 工作区动作

/// 工作区命令的执行入口。
///
/// 设计选择（见报告与技术设计 `06-ui-layer.md` §5）：
/// **用 `@FocusedValue` + 菜单 `Commands`，不用 `NotificationCenter`。**
/// `06-ui-layer.md` §1 明确「跨边界状态传递不用通知中心」，§5 又要求快捷键走菜单 `Commands`，
/// 两者叠加的结论就是 `focusedSceneValue`：菜单直接从当前场景取到命令处理器。
///
/// 可扩展性：后续 wave 的网格 / 编辑器只需要在 `WorkspaceView` 构造本结构时
/// 把 `submitChanges` / `previewSQL` / `discardChanges` / `cancelQuery` / `find` 等
/// 可选闭包换成自己的实现；可选值为 nil 时菜单项自动禁用（如本阶段没有网格）。
struct WorkspaceActions {
    // 文件
    var newQuery: @MainActor () -> Void
    var closeTab: @MainActor () -> Void
    var importCSV: @MainActor () -> Void
    var exportData: @MainActor () -> Void
    var openScript: @MainActor () -> Void
    var saveScriptAs: @MainActor () -> Void

    // 连接
    var reconnect: @MainActor () -> Void
    var disconnect: @MainActor () -> Void
    var switchDatabase: @MainActor () -> Void
    var refresh: @MainActor () -> Void
    var toggleReadOnly: @MainActor () -> Void

    // 变更（表数据标签，后续 wave 填充）
    var submitChanges: (@MainActor () -> Void)?
    var previewSQL: (@MainActor () -> Void)?
    var discardChanges: (@MainActor () -> Void)?
    var cancelQuery: (@MainActor () -> Void)?

    // 视图
    var toggleSidebar: @MainActor () -> Void
    var toggleInspector: @MainActor () -> Void
    var toggleConsoleLog: @MainActor () -> Void
    var previousTab: @MainActor () -> Void
    var nextTab: @MainActor () -> Void
    var selectTab: @MainActor (Int) -> Void

    // 菜单标题用的当前状态
    var inspectorVisible: Bool
    var isReadOnly: Bool
    /// 当前表数据标签的待提交条数（0 时提交 / 预览 / 放弃禁用）。
    var pendingChangeCount: Int

    // 查找（⌘F / ⌥⌘F）；本阶段 ⌘F 聚焦对象树搜索框
    var find: (@MainActor () -> Void)?
    var findColumns: (@MainActor () -> Void)?
}

private struct WorkspaceActionsKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

extension FocusedValues {
    var appActions: AppActions? {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }

    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

// MARK: - 菜单栏

/// 应用菜单栏。按 `specs/02-workspace.md` §8、§9 组织。
///
/// 本阶段没有网格 / 编辑器，它们的命令（提交 / 预览 / 放弃 / 取消查询 / 列过滤）
/// 保留菜单项但处于禁用状态；后续 wave 通过 `WorkspaceActions` 的对应闭包挂上实现。
struct TableLiteCommands: Commands {

    @FocusedValue(\.appActions) private var app
    @FocusedValue(\.workspaceActions) private var workspace

    var body: some Commands {
        appMenu
        fileMenu
        editMenu
        connectionMenu
        queryMenu
        viewMenu
        helpMenu
    }

    // MARK: TableLite

    @CommandsBuilder
    private var appMenu: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 TableLite") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("偏好设置…") { app?.openPreferences() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(app == nil)
        }
    }

    // MARK: 文件

    @CommandsBuilder
    private var fileMenu: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建连接") { app?.newConnection?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(app?.newConnection == nil)

            Button("新建查询") { workspace?.newQuery() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(workspace == nil)

            Button("关闭标签") { workspace?.closeTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(workspace == nil)

            Divider()

            Button("导入 CSV…") { workspace?.importCSV() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Button("导出…") { workspace?.exportData() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Button("打开脚本…") { workspace?.openScript() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(workspace == nil)

            Button("脚本另存为…") { workspace?.saveScriptAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }
        // 单窗口应用：去掉系统的 Save / Import & Export 组，避免与上面的项重复。
        CommandGroup(replacing: .saveItem) { }
        CommandGroup(replacing: .importExport) { }
    }

    // MARK: 编辑

    @CommandsBuilder
    private var editMenu: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            // 注释切换 / 缩进 / 反缩进属于 SQL 编辑器（P7），本阶段留位禁用。
            Button("注释切换") { }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(true)
            Button("缩进") { }
                .disabled(true)
            Button("反缩进") { }
                .disabled(true)
            Divider()
            Button("查找") { workspace?.find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspace?.find == nil)
            // 列过滤属于网格（P6），本阶段留位。
            Button("列过滤") { workspace?.findColumns?() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(workspace?.findColumns == nil)
        }
    }

    // MARK: 查询

    // 执行相关命令的落点随当前标签变化（网格是「提交」、编辑器是「执行」），
    // 见 `06-ui-layer.md` §5；本阶段没有内容标签，留位禁用。
    @CommandsBuilder
    private var queryMenu: some Commands {
        CommandMenu("查询") {
            // 同一组按键的落点随当前标签变化：表数据标签是「提交修改」，
            // 查询标签是「执行光标所在语句」（P7 实现后放开）。见 `specs/02-workspace.md` §9。
            Button(workspace?.submitChanges != nil ? "提交修改" : "执行光标所在语句") {
                workspace?.submitChanges?()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(workspace?.submitChanges == nil)
            Button("执行全部") { }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(true)
        }
    }

    // MARK: 连接

    @CommandsBuilder
    private var connectionMenu: some Commands {
        CommandMenu("连接") {
            Button("重新连接") { workspace?.reconnect() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Button("断开连接") { workspace?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Button("切换数据库…") { workspace?.switchDatabase() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(workspace == nil)

            Button("刷新") { workspace?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workspace == nil)

            Divider()

            Button("提交修改") { workspace?.submitChanges?() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workspace?.submitChanges == nil || (workspace?.pendingChangeCount ?? 0) == 0)

            Button("预览 SQL") { workspace?.previewSQL?() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(workspace?.previewSQL == nil || (workspace?.pendingChangeCount ?? 0) == 0)

            Button("放弃修改") { workspace?.discardChanges?() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(workspace?.discardChanges == nil || (workspace?.pendingChangeCount ?? 0) == 0)

            Button("取消查询") { workspace?.cancelQuery?() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(workspace?.cancelQuery == nil)

            Divider()

            Button(workspace?.readOnlyToggleTitle ?? "只读模式") { workspace?.toggleReadOnly() }
                .disabled(workspace == nil)
        }
    }

    // MARK: 视图

    @CommandsBuilder
    private var viewMenu: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button("显示/隐藏左侧栏") { workspace?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(workspace == nil)

            // 右侧字段栏按 S15 不设快捷键。
            Button(workspace?.inspectorToggleTitle ?? "显示/隐藏右侧字段栏") { workspace?.toggleInspector() }
                .disabled(workspace == nil)

            Button("显示/隐藏 Console Log") { workspace?.toggleConsoleLog() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(workspace == nil)

            Divider()

            Button("上一个标签") { workspace?.previousTab() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(workspace == nil)

            Button("下一个标签") { workspace?.nextTab() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(workspace == nil)

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button("标签 \(number)") { workspace?.selectTab(number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                    .disabled(workspace == nil)
            }
        }
    }

    // MARK: 帮助

    @CommandsBuilder
    private var helpMenu: some Commands {
        CommandGroup(replacing: .help) {
            Button("使用说明") { app?.showHelp() }
                .disabled(app == nil)
            Button("打开数据目录") { app?.openDataDirectory() }
                .disabled(app == nil)
        }
    }
}

// MARK: - 菜单标题

private extension WorkspaceActions {
    /// 「视图」菜单里字段栏开关的标题随当前状态变化。
    var inspectorToggleTitle: String {
        inspectorVisible ? "隐藏右侧字段栏" : "显示右侧字段栏"
    }

    var readOnlyToggleTitle: String {
        isReadOnly ? "只读模式（已开启）" : "只读模式"
    }
}
