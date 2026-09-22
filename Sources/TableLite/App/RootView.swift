import SwiftUI

/// 应用根视图占位。
///
/// 真正的连接列表与工作区由后续 Wave 填充；这里只按「有没有活动会话」做最简单的分流，
/// 让 App 能启动、能把 `AppEnvironment` 注入到 SwiftUI environment。
///
/// 挂载点：
/// - 无连接 → 连接列表占位（`specs/01-connections.md` §1、§7）
/// - 有活动会话 → 工作区占位（`specs/02-workspace.md` §1）
struct RootView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // TODO(Wave UI): 替换为真正的 ConnectionsView / WorkspaceView。
        if environment.sessionManager.sessions.isEmpty {
            placeholder(
                title: "选择一个连接开始",
                detail: "连接列表待后续 Wave 实现"
            )
        } else {
            placeholder(
                title: environment.sessionManager.activeSession?.connection.name ?? "工作区",
                detail: "工作区（工具栏 / 对象树 / 标签 / 状态栏）待后续 Wave 实现"
            )
        }
    }

    private func placeholder(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Text("TableLite")
                .font(.largeTitle.bold())
            Text(title)
                .font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 520, minHeight: 360)
        .padding(24)
    }
}
