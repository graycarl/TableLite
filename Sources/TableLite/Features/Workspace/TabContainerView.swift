import SwiftUI
import AppKit

/// 标签内容区：标签条 + 内容。
///
/// 性能按 `docs/tech-designs/06-ui-layer.md` §7：
/// - 内容用 `ZStack` + `opacity` 保持存活，**不用 `if` 切换**，避免切回来重建；
/// - 首次激活时才创建内容（惰性），之后一直保留（T3 的全部保活策略）。
struct TabContainerView: View {

    let session: ConnectionSession
    var onNewQuery: () -> Void

    @State private var materialized: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(session: session, onNewQuery: onNewQuery)
            ZStack {
                content
                if showsOverlay {
                    SessionStateOverlay(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: session.activeTabID, initial: true) { _, newValue in
            if let newValue {
                materialized.insert(newValue)
            }
        }
        .onChange(of: session.tabs.map(\.id)) { _, ids in
            materialized.formIntersection(Set(ids))
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.tabs.isEmpty {
            emptyState
        } else {
            ForEach(session.tabs) { tab in
                if materialized.contains(tab.id) {
                    TabContentView(session: session, tab: tab)
                        .opacity(tab.id == session.activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == session.activeTabID)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("打开一个表，或新建查询标签")
                .foregroundStyle(.secondary)
            Button("新建查询") { onNewQuery() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// 已断开 / 已回收 / 连接失败时盖一层遮罩（`specs/02-workspace.md` §10）。
    private var showsOverlay: Bool {
        switch session.state {
        case .connected: return false
        case .connecting: return false
        case .disconnected, .recycled, .failed: return true
        }
    }
}

/// 侧栏 / 字段栏的拖拽手柄。
struct ResizeHandle: View {

    /// 拖动回调，参数是本帧的水平位移增量（pt）。
    var onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let delta = value.translation.width - lastTranslation
                        lastTranslation = value.translation.width
                        onDrag(delta)
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
    }
}
