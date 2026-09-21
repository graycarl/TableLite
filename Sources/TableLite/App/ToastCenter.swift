import SwiftUI
import os

// MARK: - ToastCenter

/// 轻提示（Toast）。见 `specs/12-feedback.md` §1 §3：
/// 出现在窗口顶部中间，2.5 秒后淡出，不遮挡操作。
///
/// 这是跨 agent 的共享契约：
/// ```swift
/// @EnvironmentObject var toasts: ToastCenter
/// toasts.show("已提交 7 处修改 · 128 ms")
/// ```
@MainActor
final class ToastCenter: ObservableObject {

    /// 自动淡出时间，见 `specs/12-feedback.md` §3。
    static let autoDismissSeconds: TimeInterval = 2.5

    struct Message: Identifiable {
        let id: UUID
        var text: String
        var actionTitle: String?
        var action: (() -> Void)?

        init(id: UUID = UUID(),
             text: String,
             actionTitle: String? = nil,
             action: (() -> Void)? = nil) {
            self.id = id
            self.text = text
            self.actionTitle = actionTitle
            self.action = action
        }
    }

    @Published var current: Message?

    private var dismissTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    init() {}

    /// 显示一条轻提示。`actionTitle` 非空时在文案右侧给一个按钮（例如「在 Finder 中显示」）。
    func show(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        dismissTask?.cancel()
        let message = Message(text: text, actionTitle: actionTitle, action: action)
        current = message
        let messageID = message.id
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.current?.id == messageID else { return }
            self.current = nil
            self.dismissTask = nil
        }
    }

    /// 立即收起当前轻提示。
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}

// MARK: - 覆盖层

extension View {
    /// 在视图顶部居中叠加轻提示。
    ///
    /// 显式传入 `ToastCenter`：如果放在 `.environmentObject(toasts)` 之后，
    /// 覆盖层本身不在注入范围内，用 `@EnvironmentObject` 会崩溃。
    func toastOverlay(_ toasts: ToastCenter) -> some View {
        modifier(ToastOverlayModifier(toasts: toasts))
    }
}

private struct ToastOverlayModifier: ViewModifier {
    @ObservedObject var toasts: ToastCenter

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message = toasts.current {
                    ToastBanner(message: message) { toasts.dismiss() }
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: toasts.current?.id)
    }
}

private struct ToastBanner: View {
    let message: ToastCenter.Message
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message.text)
                .font(.callout)
                .lineLimit(2)
            if let actionTitle = message.actionTitle {
                Button(actionTitle) {
                    message.action?()
                    dismiss()
                }
                .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(radius: 6, y: 2)
    }
}
