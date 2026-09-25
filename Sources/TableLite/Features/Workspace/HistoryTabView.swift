import SwiftUI
import AppKit

/// 查询历史标签（`specs/06-query-editor.md` §5、`docs/tech-designs/10-query-editor.md` §7）。
///
/// 数据来自 `history.sqlite3`；只记录从 SQL 编辑器执行的语句（由 `ConnectionSession` 统一写入）。
/// 支持按 SQL 搜索、按连接过滤、按时间范围过滤、单条删除 / 清空（`⌥` 清空全部）、
/// 双击插入当前查询标签、右键复制 / 在新标签打开 / 删除。
struct HistoryTabView: View {

    let session: ConnectionSession

    @Environment(AppEnvironment.self) private var environment
    @State private var entries: [QueryHistoryEntry] = []
    @State private var search = ""
    @State private var connectionFilter: ConnectionFilter = .all
    @State private var timeFilter: HistoryTimeFilter = .all
    @State private var selection: Int64?
    @State private var loadError: String?
    @State private var showClearConfirmation = false
    @State private var pendingClearAll = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            if let selected = selectedEntry {
                Divider()
                preview(selected)
            }
        }
        .task(id: reloadKey) { await load() }
        // 清空是破坏性操作，需要一次普通确认（`specs/12-feedback.md` §4）。
        .confirmationDialog(
            pendingClearAll ? "确定要清空全部连接的查询历史吗？" : "确定要清空当前连接的查询历史吗？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { clear() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索 SQL 内容…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Picker("连接", selection: $connectionFilter) {
                Text("全部连接").tag(ConnectionFilter.all)
                ForEach(connectionChoices, id: \.id) { choice in
                    Text(choice.name).tag(ConnectionFilter.connection(choice.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 180)

            Picker("时间", selection: $timeFilter) {
                ForEach(HistoryTimeFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 120)

            Spacer()

            Text("\(entries.count) 条")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("清空历史") {
                pendingClearAll = NSEvent.modifierFlags.contains(.option)
                showClearConfirmation = true
            }
            .buttonStyle(.subtle)
            .disabled(entries.isEmpty)
            .help("清空当前连接的记录；按住 ⌥ 清空所有连接")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView("读取查询历史失败", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else if entries.isEmpty {
            ContentUnavailableView("还没有查询历史", systemImage: "clock.arrow.circlepath")
        } else {
            List(entries, selection: $selection) { entry in
                HistoryRow(entry: entry)
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { insert(entry.sql) }
                    .contextMenu {
                        Button("复制") { copy(entry.sql) }
                        Button("插入到当前查询标签") { insert(entry.sql) }
                        Button("重新执行") { rerun(entry.sql) }
                        Button("在新标签打开") { openInNewTab(entry.sql) }
                        Divider()
                        Button("删除该条", role: .destructive) {
                            Task {
                                try? await environment.history.delete(id: entry.id)
                                await load()
                            }
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    private func preview(_ entry: QueryHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(Self.timeFormatter.string(from: entry.executedAt))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let database = entry.database {
                        Text(database).foregroundStyle(.tertiary)
                    }
                    Text("\(entry.durationMilliseconds) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(entry.sql)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .frame(height: 150)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: 数据

    private var reloadKey: String {
        "\(search)|\(connectionFilter.key)|\(timeFilter.rawValue)"
    }

    private var selectedEntry: QueryHistoryEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    private var connectionChoices: [(id: UUID, name: String)] {
        environment.sessionManager.sessions.map { ($0.id, $0.connection.name) }
    }

    private func load() async {
        do {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let connectionID: UUID?
            switch connectionFilter {
            case .all: connectionID = nil
            case .connection(let id): connectionID = id
            }
            entries = try await environment.history.recent(
                connectionID: connectionID,
                search: trimmed.isEmpty ? nil : trimmed,
                // 与存储层保留上限一致（`specs/06-query-editor.md` §5：默认保留最近 5000 条）。
                // 一次取满即可覆盖全部保留记录，保证 5000 条都可显示、可搜索。
                limit: QueryHistoryStore.defaultRetention,
                since: timeFilter.since(now: environment.clock.now)
            )
            loadError = nil
        } catch {
            loadError = "查询历史不可用：\(error)"
        }
    }

    private func clear() {
        let clearAll = pendingClearAll
        Task {
            if clearAll {
                try? await environment.history.clearAll()
            } else {
                try? await environment.history.clear(connectionID: session.id)
            }
            await load()
        }
    }

    // MARK: 动作

    private func copy(_ sql: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sql, forType: .string)
    }

    /// 插入到当前查询标签；没有查询标签时新建一个。
    private func insert(_ sql: String) {
        if let editor = session.activeTab?.content as? QueryEditorViewModel {
            editor.insertHistorySQL(sql, append: true)
        } else {
            session.newQueryTab(initialSQL: sql)
        }
    }

    private func openInNewTab(_ sql: String) {
        session.newQueryTab(initialSQL: sql)
    }

    /// 重新执行：当前有查询编辑器就直接跑，否则开一个新标签。
    private func rerun(_ sql: String) {
        if let editor = session.activeTab?.content as? QueryEditorViewModel {
            editor.insertHistorySQL(sql, append: false)
            editor.executeSQL(sql)
        } else {
            session.newQueryTab(initialSQL: sql)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - 过滤项

enum ConnectionFilter: Hashable {
    case all
    case connection(UUID)

    var key: String {
        switch self {
        case .all: return "all"
        case .connection(let id): return id.uuidString
        }
    }
}

/// 时间范围过滤（`specs/06-query-editor.md` §5）。
enum HistoryTimeFilter: String, CaseIterable, Identifiable {
    case all
    case today
    case last7Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部时间"
        case .today: return "今天"
        case .last7Days: return "最近 7 天"
        }
    }

    func since(now: Date) -> Date? {
        switch self {
        case .all:
            return nil
        case .today:
            return Calendar.current.startOfDay(for: now)
        case .last7Days:
            return Calendar.current.date(byAdding: .day, value: -7, to: now)
        }
    }
}

// MARK: - 行

/// 一条查询历史。
private struct HistoryRow: View {

    let entry: QueryHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.succeeded ? .green : .red)
                Text(Self.timeFormatter.string(from: entry.executedAt))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("\(entry.durationMilliseconds) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let rows = entry.returnedRowCount {
                    Text("\(rows) 行").foregroundStyle(.secondary)
                } else if let affected = entry.affectedRows {
                    Text("影响 \(affected) 行").foregroundStyle(.secondary)
                }
                if let database = entry.database {
                    Text(database).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Text(entry.sql)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
            if let errorMessage = entry.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
