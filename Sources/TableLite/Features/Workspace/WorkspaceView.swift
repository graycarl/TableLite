import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 工作区

/// 单窗口四层布局：工具栏 → 2pt 连接颜色带 → 主体区 → 状态栏。
///
/// 主体区横向三块：左侧栏（可拖宽、可隐藏）、标签内容区、右侧字段栏（由表数据标签自己渲染）。
/// 见 `specs/02-workspace.md` §1、`docs/tech-designs/06-ui-layer.md` §2。
///
/// 状态归属：所有状态都在 `AppEnvironment` / `SessionManager` / `ConnectionSession` 里，
/// 本视图只读状态、只发意图。
struct WorkspaceView: View {

    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        // 轻提示遮罩由根视图统一叠加（见 `TableLiteApp`），这里不再重复。
        WorkspaceContainer(sessionManager: env.sessionManager)
    }
}

// MARK: - 容器（观察 SessionManager）

private struct WorkspaceContainer: View {

    @ObservedObject var sessionManager: SessionManager
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if let session = sessionManager.activeSession {
            WorkspaceSessionView(session: session,
                                  preferences: env.preferences,
                                  sessionManager: sessionManager)
                .id(session.id)
        } else {
            WorkspaceNoSessionView(sessionManager: sessionManager,
                                   connections: env.connections)
        }
    }
}

// MARK: - 单个连接的工作区

private struct WorkspaceSessionView: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessionManager: SessionManager
    @EnvironmentObject private var env: AppEnvironment

    @StateObject private var objectTree = ObjectTreeModel()

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(session: session,
                             sessionManager: sessionManager,
                             preferences: preferences)

            WorkspaceColorBand(color: WorkspaceColorMapping.color(for: session.connection.color))

            Divider()

            HStack(spacing: 0) {
                if preferences.sidebarVisible {
                    SidebarView(session: session, objectTree: objectTree, preferences: preferences)
                        .frame(width: CGFloat(preferences.sidebarWidth))

                    SplitHandle(width: Binding(get: { preferences.sidebarWidth },
                                               set: { preferences.sidebarWidth = $0 }),
                                range: 180...480,
                                onCommit: { preferences.sidebarWidth = $0 })
                }

                VStack(spacing: 0) {
                    TabBarView(session: session, environment: env)
                    Divider()
                    TabContentView(session: session)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusBarView(session: session)
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(WorkspaceSessionShortcuts(session: session, preferences: preferences))
        .onAppear { syncObjectTree() }
        .onChange(of: session.objects) { _, _ in syncObjectTree() }
        .onChange(of: session.selectedDatabase) { _, _ in syncObjectTree() }
    }

    private func syncObjectTree() {
        objectTree.update(objects: session.objects, database: session.selectedDatabase)
    }
}

// MARK: - 未选择连接

private struct WorkspaceNoSessionView: View {

    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var connections: ConnectionStore
    @EnvironmentObject private var toasts: ToastCenter

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("选择一个连接开始")
                .font(.title3)

            if connections.connections.isEmpty {
                Text("还没有连接")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(connections.connections) { connection in
                        Button {
                            connect(connection)
                        } label: {
                            HStack(spacing: 8) {
                                WorkspaceStatusDot(state: state(for: connection.id))
                                Text(connection.name.isEmpty ? connection.mysql.host : connection.name)
                                Spacer()
                                Text(connection.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 380)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 760, minHeight: 480)
    }

    private func state(for id: UUID) -> ConnectionState {
        sessionManager.session(id: id)?.state ?? .disconnected
    }

    private func connect(_ connection: Connection) {
        Task {
            do {
                _ = try await sessionManager.connect(connection, password: nil)
                toasts.show("已连接 \(connection.name)")
            } catch {
                logger.error("连接失败：\(String(describing: error), privacy: .public)")
                toasts.show((error as? MySQLError)?.title ?? "连接失败")
            }
        }
    }
}

// MARK: - 工作区快捷键

/// 菜单栏里尚未接上 `@FocusedValue` 的工作区快捷键，用隐藏按钮承载。
/// `⇧⌘R` / `⇧⌘D` 等已在菜单里直接实现，这里不再重复；
/// `⌘F` / `⌘I` 故意不在此抢占，交给后续 wave 的 `@FocusedValue`（见 `docs/tech-designs/06-ui-layer.md` §5）。
private struct WorkspaceSessionShortcuts: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        ZStack {
            Button("") { preferences.sidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("") { session.openConsoleLogTab() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("") { refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func refresh() {
        Task {
            if let viewModel = session.activeTab?.tableData as? TableDataViewModel {
                await viewModel.refresh()
            } else if let viewModel = session.activeTab?.tableStructure as? TableStructureViewModel {
                await viewModel.refresh()
            }
            await session.refreshObjects()
        }
    }
}

// MARK: - 连接颜色带

private struct WorkspaceColorBand: View {

    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 2)
    }
}

// MARK: - 连接颜色映射

/// `ConnectionColor` → SwiftUI `Color`。独立命名空间，避免与其他 worker 的同名扩展冲突。
enum WorkspaceColorMapping {

    static func color(for color: ConnectionColor) -> Color {
        switch color {
        case .none: return Color.clear
        case .red: return Color.red
        case .orange: return Color.orange
        case .yellow: return Color.yellow
        case .green: return Color.green
        case .blue: return Color.blue
        case .purple: return Color.purple
        case .gray: return Color.gray
        }
    }
}

// MARK: - 连接状态点

/// 连接状态点：灰=未连接、黄=连接中、绿=正常、红=断开。
struct WorkspaceStatusDot: View {

    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }
}
