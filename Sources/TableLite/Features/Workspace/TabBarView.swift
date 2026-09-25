import SwiftUI

/// 标签条（`specs/02-workspace.md` §6）。
///
/// - 标签过多时横向滚动；
/// - 当前标签用圆角底色块突出，顶边 2pt 连接色（无颜色连接用系统强调色）；
///   非活动标签无分隔线，悬停出淡底（`docs/tech-designs/06-ui-layer.md` §10）；
/// - 有未提交改动时标题右侧显示橙色圆点；
/// - `⌘W` / 关闭按钮关闭当前标签，有未提交改动时先确认；
/// - 查询标签可右键重命名。
struct TabBarView: View {

    let session: ConnectionSession
    var onNewQuery: () -> Void

    @Environment(PendingChangesCoordinator.self) private var pendingChanges

    @State private var renamingTab: Tab?
    @State private var renameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(session.tabs) { tab in
                    TabItemView(
                        tab: tab,
                        isActive: tab.id == session.activeTabID,
                        accentColor: tabAccentColor,
                        onSelect: { session.selectTab(tab) },
                        onClose: { requestClose(tab) },
                        onRename: {
                            renamingTab = tab
                            renameText = tab.customTitle ?? tab.title
                        }
                    )
                }

                Button {
                    onNewQuery()
                } label: {
                    Image(systemName: "plus")
                        .font(.callout)
                }
                .buttonStyle(.subtle)
                .help("新建查询")
            }
            .padding(.horizontal, AppSpacing.xs)
        }
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .alert("重命名标签", isPresented: renamePresented) {
            TextField("标签名", text: $renameText)
            Button("确定") {
                if let renamingTab {
                    renamingTab.customTitle = renameText
                }
                renamingTab = nil
            }
            Button("取消", role: .cancel) { renamingTab = nil }
        }
    }

    /// 活动标签顶边的颜色：连接配置的颜色，无色时用系统强调色（`specs/02-workspace.md` §6）。
    private var tabAccentColor: Color {
        let connectionColor = session.connection.color
        return connectionColor == .none ? Color.accentColor : connectionColor.swiftUIColor
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renamingTab != nil },
            set: { if !$0 { renamingTab = nil } }
        )
    }

    /// 关闭前检查未提交改动（`specs/02-workspace.md` §6、`specs/04-data-editing.md` §12）；
    /// 查询标签则检查未保存文件改动（`specs/06-query-editor.md` §7）。
    private func requestClose(_ tab: Tab) {
        Task {
            if await pendingChanges.resolveCloseAnyTab(tab: tab) {
                session.closeTab(tab)
            }
        }
    }
}

/// 单个标签。
private struct TabItemView: View {

    let tab: Tab
    let isActive: Bool
    let accentColor: Color
    var onSelect: () -> Void
    var onClose: () -> Void
    var onRename: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)

            if tab.hasPendingChanges {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .help("有未提交的修改")
            }

            if isHovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭标签")
            }
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.m)
                .fill(backgroundColor)
        )
        .overlay(alignment: .top) {
            if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, AppSpacing.xs)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .contextMenu {
            if tab.kind.isQuery {
                Button("重命名…", action: onRename)
            }
            Button("关闭标签", action: onClose)
        }
    }

    private var backgroundColor: Color {
        if isActive { return Color.primary.opacity(0.10) }
        return Color.primary.opacity(isHovering ? 0.05 : 0)
    }
}
