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
        .background(AppColor.content)
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
///
/// 命中区不能是透明的：透出来的窗口白底会在浅灰侧栏与白色内容之间形成
/// 2.5pt 白色细边（深色下是反向的亮缝）。这里让 6pt 命中区填满**贴近它的
/// 那一侧**表面色，1pt 分隔线画在另一侧（`06-ui-layer.md` §10「区域分隔条」）。
struct ResizeHandle: View {

    /// 1pt 分隔线画在手柄的哪一侧。侧栏手柄的线在右（贴内容区），字段栏手柄的线在左。
    enum LineEdge {
        case leading
        case trailing
    }

    /// 命中区填充色：用相邻区域的表面色，保证与那一侧连续。
    var fill: Color
    var lineEdge: LineEdge = .trailing

    /// 拖动回调，参数是本帧的水平位移增量（pt）。
    var onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: lineEdge == .trailing ? .trailing : .leading) {
            Rectangle()
                .fill(fill)
            Rectangle()
                .fill(AppColor.rowSeparator)
                .frame(width: 1)
        }
        .frame(width: AppSpacing.xs)
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
