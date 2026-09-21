import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 标签栏

/// 当前连接的标签栏：横向滚动、标题、未提交橙点、右键菜单、中键关闭、`⌘1…⌘9`。
/// 见 `specs/02-workspace.md` §6。
struct TabBarView: View {

    @ObservedObject var session: ConnectionSession
    let environment: AppEnvironment

    @EnvironmentObject private var toasts: ToastCenter

    @State private var dialog: TabBarDialog?
    @State private var renamingTab: Tab?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabBarItem(
                            tab: tab,
                            isActive: tab.id == session.activeTabID,
                            isFirst: index == 0,
                            onSelect: { session.selectTab(tab) },
                            onClose: { requestClose(tab) },
                            onRename: { beginRename(tab) },
                            onCloseOthers: { requestCloseOthers(tab) }
                        )
                    }
                }
            }
            .alert("重命名标签", isPresented: renamingPresented) {
                TextField("标签名", text: $renameText)
                Button("取消", role: .cancel) { renamingTab = nil }
                Button("重命名") { commitRename() }
            }

            Spacer(minLength: 0)

            Button { session.newQueryTab() } label: {
                Image(systemName: "plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .help("新建查询")
        }
        .frame(height: 34)
        .background(.bar)
        .background(shortcutButtons)
        .confirmationDialog(dialogTitle,
                            isPresented: dialogPresented,
                            titleVisibility: .visible) {
            dialogActions
        } message: {
            dialogMessage
        }
    }

    // MARK: 快捷键（隐藏按钮）

    @ViewBuilder
    private var shortcutButtons: some View {
        ZStack {
            ForEach(0..<min(session.tabs.count, 9), id: \.self) { index in
                Button("") { session.selectTab(session.tabs[index]) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            // ⌘W 由菜单「文件 → 关闭标签」唯一下发，这里不再放隐藏按钮，避免双触发。
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: 绑定

    private var dialogPresented: Binding<Bool> {
        Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } })
    }

    private var renamingPresented: Binding<Bool> {
        Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })
    }

    private var dialogTitle: String {
        switch dialog {
        case .close(let tab): return "「\(tab.title)」有未提交的修改"
        case .closeOthers: return "其他标签里有未提交的修改"
        case nil: return ""
        }
    }

    @ViewBuilder
    private var dialogActions: some View {
        switch dialog {
        case .close:
            Button("提交并关闭") { commitAndClose() }
            Button("放弃并关闭", role: .destructive) { discardAndClose() }
            Button("取消", role: .cancel) { dialog = nil }
        case .closeOthers:
            Button("放弃并关闭其他标签", role: .destructive) { forceCloseOthers() }
            Button("取消", role: .cancel) { dialog = nil }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var dialogMessage: some View {
        switch dialog {
        case .close:
            Text("提交会真的写入数据库；放弃会丢弃这个标签里的全部未保存改动。")
        case .closeOthers:
            Text("这些标签里的改动会被丢弃，无法通过「放弃改动」回退。")
        case nil:
            EmptyView()
        }
    }

    // MARK: 关闭

    private func requestClose(_ tab: Tab) {
        if tab.hasPendingChanges {
            dialog = .close(tab)
        } else {
            session.closeTab(tab)
        }
    }

    private func commitAndClose() {
        guard case .close(let tab) = dialog else { return }
        dialog = nil
        Task {
            if let viewModel = tab.tableData as? TableDataViewModel {
                do {
                    _ = try await viewModel.commit()
                } catch {
                    logger.error("关闭标签前提交失败：\(String(describing: error), privacy: .public)")
                    toasts.show((error as? MySQLError)?.title ?? "提交失败")
                    return
                }
            }
            session.closeTab(tab)
        }
    }

    private func discardAndClose() {
        guard case .close(let tab) = dialog else { return }
        dialog = nil
        Task {
            if let viewModel = tab.tableData as? TableDataViewModel {
                await viewModel.discardAll()
            }
            session.closeTab(tab)
        }
    }

    private func requestCloseOthers(_ tab: Tab) {
        let others = session.tabs.filter { $0.id != tab.id }
        if others.contains(where: \.hasPendingChanges) {
            dialog = .closeOthers(tab)
        } else {
            for other in others { session.closeTab(other) }
            session.selectTab(tab)
        }
    }

    private func forceCloseOthers() {
        guard case .closeOthers(let tab) = dialog else { return }
        dialog = nil
        let others = session.tabs.filter { $0.id != tab.id }
        Task {
            for other in others {
                if let viewModel = other.tableData as? TableDataViewModel, other.hasPendingChanges {
                    await viewModel.discardAll()
                }
                session.closeTab(other)
            }
            session.selectTab(tab)
        }
    }

    // MARK: 重命名

    private func beginRename(_ tab: Tab) {
        renameText = tab.title
        renamingTab = tab
    }

    private func commitRename() {
        guard let tab = renamingTab else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        renamingTab = nil
    }
}

// MARK: - 标签栏对话框

private enum TabBarDialog {
    case close(Tab)
    case closeOthers(Tab)
}

// MARK: - 单个标签

private struct TabBarItem: View {

    @ObservedObject var tab: Tab
    let isActive: Bool
    let isFirst: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onCloseOthers: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title)
                .lineLimit(1)
            if tab.hasPendingChanges {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
            if isHovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭标签（⌘W）")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(minWidth: 96, alignment: .leading)
        .background(isActive ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay(alignment: .leading) {
            if !isFirst {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
        .background(MiddleClickCatcher(action: onClose))
        .contextMenu {
            Button("重命名…") { onRename() }
            Divider()
            Button("关闭") { onClose() }
            Button("关闭其他") { onCloseOthers() }
        }
    }
}

// MARK: - 中键点击

/// 捕获鼠标中键：SwiftUI 的 `onTapGesture` 拿不到按键号，这里用一条本地事件监视器，
/// 命中本视图 bounds 的 `.otherMouseUp` 触发关闭并吞掉事件。
private struct MiddleClickCatcher: NSViewRepresentable {

    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.action = action
    }

    final class CatcherView: NSView {

        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak self] event in
                guard let self else { return event }
                guard let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.action?()
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
