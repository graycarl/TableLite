import SwiftUI

/// 库切换器（`specs/02-workspace.md` §4）。
///
/// - 列出当前连接可访问的所有库；
/// - 库少时用下拉菜单，库多时用带搜索框的浮层；
/// - 配置里的库不存在时显示告警（`session.unresolvedDatabase`）。
struct DatabaseSwitcher: View {

    let session: ConnectionSession

    @State private var showPopover = false

    /// 超过这个数量就改用带搜索框的浮层。
    private static let menuThreshold = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.databases.count > Self.menuThreshold {
                Button {
                    showPopover = true
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    DatabasePickerList(session: session) { showPopover = false }
                        .frame(width: 280, height: 340)
                }
            } else {
                Menu {
                    pickerMenu
                } label: {
                    label
                }
                .menuStyle(.borderlessButton)
                .disabled(session.databases.isEmpty)
            }

            if let unresolved = session.unresolvedDatabase {
                Label("连接配置里的数据库 \(unresolved) 不存在", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if let notice = session.databaseSwitchNotice {
                Label(notice, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.secondary)
            Text(session.selectedDatabase ?? "请选择数据库")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var pickerMenu: some View {
        Picker("数据库", selection: selection) {
            ForEach(session.databases, id: \.self) { database in
                Text(database).tag(Optional(database))
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { session.selectedDatabase },
            set: { newValue in
                Task { await session.selectDatabase(newValue) }
            }
        )
    }
}

/// 带搜索的库列表，供浮层与 `⌘K` 面板共用。
struct DatabasePickerList: View {

    let session: ConnectionSession
    var onSelect: (() -> Void)?

    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索数据库", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)

            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("没有匹配的数据库")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.self) { database in
                            Button {
                                Task { await session.selectDatabase(database) }
                                onSelect?()
                            } label: {
                                HStack {
                                    Text(database)
                                        .lineLimit(1)
                                    Spacer()
                                    if database == session.selectedDatabase {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var filtered: [String] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return session.databases }
        return session.databases.filter { $0.range(of: trimmed, options: .caseInsensitive) != nil }
    }
}
