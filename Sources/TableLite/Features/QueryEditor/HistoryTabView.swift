import AppKit
import SwiftUI
import os

// MARK: - 查询历史
//
// 搜索 / 连接过滤 / 时间范围 + 列表（时间 / 成败 / 耗时 / 行数 / SQL 摘要）。
// 单击预览完整 SQL，双击插入到当前查询标签，右键复制 / 新标签打开 / 删除，清空（⌥ 清空全部）。
// 见 specs/06-query-editor.md §5、docs/tech-designs/02-persistence.md §4。
//
// 跨文件契约：工作区外壳按 `HistoryTabView(session:tab:environment:)` 装配。

struct HistoryTabView: View {
    let session: ConnectionSession
    let tab: Tab
    let environment: AppEnvironment

    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var model: HistoryViewModel

    @State private var timeRange: TimeRange = .all
    @State private var showingClearConfirm = false
    @State private var clearingAll = false

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    enum TimeRange: String, CaseIterable, Identifiable {
        case all
        case today

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "全部时间"
            case .today: return "今天"
            }
        }
    }

    init(session: ConnectionSession, tab: Tab, environment: AppEnvironment) {
        self.session = session
        self.tab = tab
        self.environment = environment
        _model = StateObject(wrappedValue: HistoryViewModel(
            connectionID: session.id,
            connections: environment.connections,
            history: environment.history,
            clock: environment.clock
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            list
            Divider()
            preview
        }
        .task { await model.reload() }
        .alert("清空查询历史", isPresented: $showingClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) {
                let clearAll = clearingAll
                Task {
                    await model.clear(connectionID: clearAll ? nil : session.id)
                    toasts.show(clearAll ? "已清空全部查询历史" : "已清空当前连接的查询历史",
                                actionTitle: nil, action: nil)
                }
            }
        } message: {
            Text(clearingAll
                 ? "将删除所有连接的查询历史，无法撤销。"
                 : "将删除当前连接的查询历史，无法撤销。")
        }
    }

    // MARK: 过滤栏

    private var filterBar: some View {
        HStack(spacing: 8) {
            TextField("搜索 SQL", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)

            Picker("", selection: $model.connectionFilter) {
                Text("全部连接").tag(UUID?.none)
                ForEach(model.availableConnections) { connection in
                    Text(model.displayName(for: connection.id)).tag(Optional(connection.id))
                }
            }
            .labelsHidden()
            .frame(width: 170)

            Picker("", selection: $timeRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            Spacer()

            Button("清空历史") {
                clearingAll = NSEvent.modifierFlags.contains(.option)
                showingClearConfirm = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: 列表

    private var entries: [HistoryRepository.Entry] {
        guard timeRange == .today else { return model.entries }
        let calendar = Calendar.current
        return model.entries.filter { calendar.isDateInToday($0.executedAt) }
    }

    private var list: some View {
        List(selection: $model.selectedEntry) {
            ForEach(entries) { entry in
                row(entry)
                    .tag(entry)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { insert(entry) }
                    .contextMenu { contextMenu(entry) }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }

    private func row(_ entry: HistoryRepository.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                .frame(width: 14)

            Text(Self.timeText(entry.executedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            Text(QueryTabLogic.elapsedText(entry.elapsed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)

            Text(rowCountText(entry))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)

            Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(1)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.vertical, 2)
    }

    private func rowCountText(_ entry: HistoryRepository.Entry) -> String {
        if let rowCount = entry.rowCount { return "\(QueryTabLogic.grouped(rowCount)) 行" }
        if let affected = entry.affectedRows { return "影响 \(QueryTabLogic.grouped(affected))" }
        if let code = entry.errorCode { return "错误 \(code)" }
        return ""
    }

    // MARK: 预览

    @ViewBuilder
    private var preview: some View {
        Group {
            if let entry = model.selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                            Text(Self.timeText(entry.executedAt))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("耗时 \(QueryTabLogic.elapsedText(entry.elapsed))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let database = entry.database, !database.isEmpty {
                                Text(database)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Text(entry.sql)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            } else {
                Text("单击一条记录查看完整 SQL")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 180)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: 动作

    @ViewBuilder
    private func contextMenu(_ entry: HistoryRepository.Entry) -> some View {
        Button("复制") { copy(entry.sql) }
        Button("在新标签打开") { session.newQueryTab(initialSQL: entry.sql) }
        Divider()
        Button("删除该条") {
            Task { await model.delete(entry) }
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        toasts.show("已复制", actionTitle: nil, action: nil)
    }

    private func insert(_ entry: HistoryRepository.Entry) {
        if let query = session.activeTab?.query as? QueryTabViewModel {
            insert(entry.sql, into: query)
        } else {
            session.newQueryTab(initialSQL: entry.sql)
        }
    }

    private func insert(_ sql: String, into query: QueryTabViewModel) {
        let ns = query.sql as NSString
        let length = ns.length
        let location = min(max(0, query.selectedRange.location), length)
        let prefix = ns.substring(to: location)
        let suffix = ns.substring(from: location)

        let separatorBefore = (!prefix.isEmpty && !prefix.hasSuffix("\n")) ? "\n" : ""
        let separatorAfter = (!suffix.isEmpty && !sql.hasSuffix("\n")) ? "\n" : ""
        let inserted = separatorBefore + sql
        let newText = prefix + inserted + separatorAfter + suffix

        query.sql = newText
        let cursor = ((prefix + inserted) as NSString).length
        query.cursorLocation = cursor
        query.selectedRange = NSRange(location: cursor, length: 0)
    }

    // MARK: 时间格式

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 " + timeFormatter.string(from: date)
        }
        return dayFormatter.string(from: date)
    }
}
