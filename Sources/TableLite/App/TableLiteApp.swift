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
        // 隐藏的编辑 / 过滤 / 查询链路端到端模式（`--edit-smoke` / `--filter-smoke` / `--query-smoke`）：
        // 不碰真实数据目录，也不在 init 里阻塞等待。
        let isHeadlessSmoke = EditSmokeRunner.isRequested || FilterSmokeRunner.isRequested || QuerySmokeRunner.isRequested
        _environment = State(initialValue: isHeadlessSmoke ? AppEnvironment.makeFallback() : AppEnvironment.makeLiveOrFallback())
        EditSmokeRunner.scheduleIfRequested()
        FilterSmokeRunner.scheduleIfRequested()
        QuerySmokeRunner.scheduleIfRequested()
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
/// `applicationShouldTerminate` 返回 `.terminateLater`，先对逐个有未提交改动的标签
/// 弹「提交 / 放弃 / 取消」，全部处理完再跑退出清理
/// （关闭 MySQL 会话、停止隧道、flush Console Log），完成后回 `terminateNow`。
/// 见 `docs/tech-designs/05-session-management.md` §7、`specs/04-data-editing.md` §12。
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
            let canProceed = await resolvePendingChanges(environment: environment)
            guard canProceed else {
                self.isTerminating = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            await environment.prepareForTermination()
            self.didShutdown = true
            self.isTerminating = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 逐个有暂存的标签弹确认；提交失败或取消则中止退出。
    private func resolvePendingChanges(environment: AppEnvironment) async -> Bool {
        while true {
            let models = environment.sessionManager.sessions
                .flatMap { PendingChangesCoordinator.pendingModels(in: $0) }
            guard let model = models.first, model.hasPendingChanges else { return true }
            switch presentPendingChangesAlert(model: model) {
            case .cancel:
                return false
            case .discard:
                await model.discardChanges()
            case .submit:
                if !(await model.submitChanges()) { return false }
            }
        }
    }

    /// 退出流程用 AppKit 模态告警；按钮文案遵循 `specs/12-feedback.md` §4。
    private func presentPendingChangesAlert(model: TableDataViewModel) -> PendingChangesCoordinator.Decision {
        let alert = NSAlert()
        alert.messageText = "有未提交的修改"
        alert.informativeText = "「\(model.tab.title)」有 \(model.pendingCount) 处未提交的修改。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "提交")
        alert.addButton(withTitle: "放弃并关闭")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .submit
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
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
