import SwiftUI

// MARK: - 左侧栏

/// 左侧栏：顶部库切换下拉 → 对象树 → 底部的查询历史 / Console Log 入口。
/// 见 `specs/02-workspace.md` §1、§4、§5。
struct SidebarView: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var objectTree: ObjectTreeModel
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        VStack(spacing: 0) {
            DatabasePicker(session: session, preferences: preferences)
            Divider()
            ObjectTreeView(session: session, objectTree: objectTree)
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            SidebarFooterButton(title: "查询历史", systemImage: "clock.arrow.circlepath") {
                session.openHistoryTab()
            }
            SidebarFooterButton(title: "Console Log", systemImage: "list.bullet.rectangle") {
                session.openConsoleLogTab()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SidebarFooterButton: View {

    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: - 库切换器

private struct DatabasePicker: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var preferences: PreferencesStore

    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(.secondary)
                Text(session.selectedDatabase ?? "选择数据库")
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .disabled(!session.state.isConnected)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            DatabaseListPopover(session: session,
                                preferences: preferences,
                                isPresented: $showingPopover)
        }
        .onChange(of: preferences.showSystemDatabases) { _, _ in
            Task { await session.reloadDatabases() }
        }
    }
}

private struct DatabaseListPopover: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var preferences: PreferencesStore
    @Binding var isPresented: Bool

    @State private var search = ""

    private var databases: [String] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return session.databases }
        return session.databases.filter { $0.lowercased().contains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索数据库…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            Toggle("显示系统数据库", isOn: systemToggle)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            Divider()

            if databases.isEmpty {
                Text("没有匹配的数据库")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(databases, id: \.self) { database in
                            Button {
                                select(database)
                            } label: {
                                HStack {
                                    Text(database).lineLimit(1)
                                    Spacer()
                                    if database == session.selectedDatabase {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 220)
            }
        }
        .frame(width: 260)
    }

    private var systemToggle: Binding<Bool> {
        Binding(get: { preferences.showSystemDatabases },
                set: { preferences.showSystemDatabases = $0 })
    }

    private func select(_ database: String) {
        session.selectedDatabase = database
        isPresented = false
        Task { await session.refreshObjects() }
    }
}
