import AppKit
import Foundation
import os

// MARK: - 退出时的未提交改动

/// 退出前需要处理的未提交改动。
///
/// `TableDataViewModel` 通过下面的扩展实现它，App 退出时 `AppDelegate` 据此
/// 提供「提交 / 放弃并关闭 / 取消关闭」三选一。
/// 见 `docs/tech-designs/05-session-management.md` §7、`specs/12-feedback.md` §4。
@MainActor
protocol TerminationPendingChangeHandler: AnyObject {
    func commitPendingChangesForTermination() async throws
    func discardPendingChangesForTermination() async
}

extension TableDataViewModel: TerminationPendingChangeHandler {
    func commitPendingChangesForTermination() async throws {
        _ = try await commit()
    }

    func discardPendingChangesForTermination() async {
        await discardAll()
    }
}

// MARK: - AppDelegate

/// 应用生命周期代理。
///
/// - `applicationShouldTerminate` 返回 `.terminateLater`：先处理所有有未提交改动的标签，
///   再 `await env.shutdown()`（持久化会话骨架 → 关闭 MySQL → 停隧道 → flush Console Log），
///   最后 `reply(toApplicationShouldTerminate:)`。见 `docs/tech-designs/05-session-management.md` §7。
/// - `applicationWillTerminate` 只是兜底：正常路径已经清理完，这里不阻塞退出。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 由 `TableLiteApp.init()` 注入。
    var environment: AppEnvironment?

    private var isTerminating = false
    private var didShutdown = false
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let environment else {
            logger.error("退出时 AppEnvironment 为空，跳过清理")
            return .terminateNow
        }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        let pending = environment.sessionManager.sessions.flatMap { session -> [PendingTab] in
            session.tabs.filter(\.hasPendingChanges).map { PendingTab(session: session, tab: $0) }
        }

        Task { @MainActor in
            let shouldTerminate = await processTermination(pending: pending, environment: environment)
            isTerminating = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !didShutdown, let environment else { return }
        // 走到这里说明正常清理没有跑完（例如被强制结束）。尽力关闭会话与隧道，
        // 但不阻塞退出。硬约束「退出后不得残留 ssh 进程」由正常路径保证。
        logger.warning("applicationWillTerminate 兜底：正常退出清理未走完，尽力关闭会话")
        let manager = environment.sessionManager
        Task { await manager.disconnectAll() }
    }

    // MARK: 私有

    private struct PendingTab {
        let session: ConnectionSession
        let tab: Tab
    }

    private enum Choice {
        case commit
        case discard
        case cancel
    }

    private func processTermination(pending: [PendingTab],
                                    environment: AppEnvironment) async -> Bool {
        for item in pending {
            switch ask(for: item) {
            case .cancel:
                return false

            case .discard:
                if let handler = item.tab.tableData as? TerminationPendingChangeHandler {
                    await handler.discardPendingChangesForTermination()
                }

            case .commit:
                guard let handler = item.tab.tableData as? TerminationPendingChangeHandler else {
                    // 没有可用的提交入口（标签尚未装配 ViewModel）时不做危险操作，直接询问取消。
                    logger.error("标签「\(item.tab.title, privacy: .public)」缺少提交入口，取消退出")
                    return false
                }
                do {
                    try await handler.commitPendingChangesForTermination()
                } catch {
                    present(error: error, tab: item.tab)
                    return false
                }
            }
        }

        await environment.shutdown()
        didShutdown = true
        return true
    }

    private func ask(for item: PendingTab) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(item.tab.title)」有未提交的修改"
        alert.informativeText = "退出前需要先处理这些改动。"
        alert.addButton(withTitle: "提交并关闭")
        alert.addButton(withTitle: "放弃并关闭")
        alert.addButton(withTitle: "取消关闭")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .commit
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    /// 错误面板：标题一句话 + 原始错误原文 + 影响说明。见 `specs/12-feedback.md` §5。
    private func present(error: Error, tab: Tab) {
        let alert = NSAlert()
        alert.alertStyle = .critical

        var text = ""
        if let mysqlError = error as? MySQLError {
            alert.messageText = mysqlError.title
            if let serverError = mysqlError.serverError {
                text = serverError.formatted
                if let hint = serverError.chineseHint {
                    text += "\n\n\(hint)"
                }
            } else if case .connect(let step, let message, let detail) = mysqlError {
                text = "发生在：\(step.displayName)\n\n\(message)"
                if let detail, !detail.isEmpty {
                    text += "\n\(detail)"
                }
            } else {
                text = mysqlError.title
            }
        } else {
            alert.messageText = "提交未完成"
            text = String(describing: error)
        }
        text += "\n\n修改尚未提交，返回后可以重试。"
        alert.informativeText = text
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }
}
