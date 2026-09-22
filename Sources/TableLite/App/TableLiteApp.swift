import SwiftUI
import AppKit

/// 应用入口。
///
/// `--smoke` 时跑完 C shim 的端到端验证就直接退出，不启动 GUI
/// （见 `Sources/TableLite/Core/MySQL/SmokeRunner.swift`，这条路径保持不变）。
///
/// 真正的界面见 `specs/02-workspace.md`，实现见 `docs/tech-designs/06-ui-layer.md`。
@main
struct TableLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment

    init() {
        SmokeRunner.runIfRequested()
        _environment = State(initialValue: AppEnvironment.makeLiveOrFallback())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    // 装配（恢复会话骨架 / 孤儿草稿清理 / 启动空闲回收与保活）。
                    appDelegate.environment = environment
                    await environment.start()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // 单窗口应用：不要「新建窗口」；其余菜单见 `TableLiteCommands`。
            TableLiteCommands()
        }
    }
}

/// 应用生命周期代理。
///
/// `applicationShouldTerminate` 返回 `.terminateLater`，先跑退出清理
/// （关闭 MySQL 会话、停止隧道、flush Console Log），完成后回 `terminateNow`。
/// 见 `docs/tech-designs/05-session-management.md` §7。
///
/// TODO(Wave P5): 退出前先对有未提交改动的标签弹「提交 / 放弃 / 取消关闭」。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 由 `TableLiteApp.body` 的任务注入。
    var environment: AppEnvironment?

    private var isTerminating = false
    private var didShutdown = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment, !isTerminating else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            await environment.prepareForTermination()
            didShutdown = true
            isTerminating = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !didShutdown, let environment else { return }
        // 兜底：正常清理没跑完（例如被强制结束）时尽力关闭会话与隧道，
        // 但不阻塞退出。硬约束「退出后不得残留 ssh 进程」由正常路径保证。
        StoreLog.warning("applicationWillTerminate 兜底：正常退出清理未走完，尽力关闭会话")
        let manager = environment.sessionManager
        Task { await manager.prepareForTermination() }
    }
}
