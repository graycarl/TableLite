import SwiftUI
import Observation

/// 未提交改动的确认流程（`specs/04-data-editing.md` §12、`docs/tech-designs/05-session-management.md` §6/§7）。
///
/// 关闭标签 / 断开或移除连接 / 退出 App 前，对涉及的标签弹「提交 / 放弃 / 取消」。
/// 这里只负责提问与执行决定；对话框的呈现由 `WorkspaceView` 用 `confirmationDialog` 完成，
/// 因此本类型可以脱离视图单测。
@MainActor
@Observable
final class PendingChangesCoordinator {

    enum Decision: Sendable, Equatable {
        case submit
        case discard
        case cancel
    }

    struct Request: Identifiable, Equatable {
        public let id = UUID()
        var title: String
        var message: String
    }

    var request: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<Decision, Never>?

    /// 弹一个三选一确认框，等用户选择。
    func ask(title: String = "有未提交的修改", message: String) async -> Decision {
        request = Request(title: title, message: message)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// 由对话框按钮 / 退出流程调用。
    func decide(_ decision: Decision) {
        let continuation = self.continuation
        self.continuation = nil
        request = nil
        continuation?.resume(returning: decision)
    }

    /// 对话框被 Esc / 点外部关闭时按「取消」处理。
    func dismissWithoutDecision() {
        guard continuation != nil else { return }
        decide(.cancel)
    }

    /// 执行决定：提交（任一失败则中止）/ 放弃 / 取消。
    @discardableResult
    func resolve(models: [TableDataViewModel], message: String) async -> Bool {
        let pending = models.filter(\.hasPendingChanges)
        guard !pending.isEmpty else { return true }
        let decision = await ask(message: message)
        switch decision {
        case .cancel:
            return false
        case .discard:
            for model in pending { await model.discardChanges() }
            return true
        case .submit:
            for model in pending {
                if !(await model.submitChanges()) { return false }
            }
            return true
        }
    }

    /// 关闭单个标签前的确认。
    @discardableResult
    func resolveClose(tab: Tab) async -> Bool {
        guard let model = tab.content as? TableDataViewModel else { return true }
        return await resolve(models: [model], message: Self.message(for: [model]))
    }

    /// 关闭任意标签前的确认：表数据标签走「提交 / 放弃 / 取消」，
    /// 查询标签走「保存 / 不保存 / 取消」（`specs/06-query-editor.md` §7）。
    @discardableResult
    func resolveCloseAnyTab(tab: Tab) async -> Bool {
        if let editor = tab.content as? QueryEditorViewModel {
            return await editor.resolveClosePrompt()
        }
        return await resolveClose(tab: tab)
    }

    /// 该会话里所有有未保存文件改动的查询标签。
    static func queryEditors(in session: ConnectionSession) -> [QueryEditorViewModel] {
        session.tabs.compactMap { $0.content as? QueryEditorViewModel }
            .filter(\.hasUnsavedFileChanges)
    }

    /// 断开 / 移除连接前的确认（汇总该会话的所有暂存标签）。
    @discardableResult
    func resolveLeave(session: ConnectionSession) async -> Bool {
        let models = Self.pendingModels(in: session)
        return await resolve(models: models, message: Self.message(for: models))
    }

    /// 退出 App 前的确认：逐个有暂存的标签弹确认（05 §7）。
    @discardableResult
    func resolveTermination(sessions: [ConnectionSession]) async -> Bool {
        for session in sessions {
            for model in Self.pendingModels(in: session) {
                guard model.hasPendingChanges else { continue }
                let decision = await ask(message: Self.message(for: [model]))
                switch decision {
                case .cancel:
                    return false
                case .discard:
                    await model.discardChanges()
                case .submit:
                    if !(await model.submitChanges()) { return false }
                }
            }
        }
        return true
    }

    static func pendingModels(in session: ConnectionSession) -> [TableDataViewModel] {
        session.tabs.compactMap { $0.content as? TableDataViewModel }.filter(\.hasPendingChanges)
    }

    static func message(for models: [TableDataViewModel]) -> String {
        let total = models.reduce(0) { $0 + $1.pendingCount }
        if models.count <= 1 {
            return "当前标签有 \(total) 处未提交的修改。"
        }
        return "有 \(total) 处未提交的修改，涉及 \(models.count) 个标签。"
    }
}
