import SwiftUI
import AppKit

/// Console Log 标签（`specs/06-query-editor.md` §6、`docs/tech-designs/10-query-editor.md` §8）。
///
/// 记录**所有**下发到服务器的语句（含元数据查询、事务控制、`KILL QUERY`），
/// 由 Core 层自动写入（`ConsoleLogStore`），本视图只读展示。
/// 支持按类别过滤、展开看完整 SQL 与结果概要、复制、清空、自动跟随底部。
struct ConsoleLogTabView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var filter: ConsoleLogFilter = .all
    @State private var expandedIDs: Set<UInt64> = []
    @State private var isFollowing = true
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        // 清空是破坏性操作，需要一次普通确认（`specs/12-feedback.md` §4）。
        .confirmationDialog(
            "确定要清空 Console Log 吗？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { environment.consoleLog.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清空内存中的记录，已写入的日志文件不受影响。")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("类别", selection: $filter) {
                ForEach(ConsoleLogFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 160)

            Spacer()

            Text("\(visibleEntries.count) 条")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("回到底部") {
                withAnimation { isFollowing = true }
            }
            .disabled(isFollowing)
            .help("继续跟随最新记录")

            Button("复制") { copyAll() }
                .disabled(visibleEntries.isEmpty)
            Button("清空") { showClearConfirmation = true }
                .disabled(environment.consoleLog.entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if visibleEntries.isEmpty {
            ContentUnavailableView("还没有语句记录", systemImage: "terminal")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleEntries) { entry in
                            ConsoleLogRow(
                                entry: entry,
                                isExpanded: expandedIDs.contains(entry.id),
                                onToggle: { toggle(entry.id) }
                            )
                            .id(entry.id)
                            Divider()
                        }
                        // 底部哨兵：可见时说明已滚到底部，恢复跟随。
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                            .onAppear { isFollowing = true }
                            .onDisappear { isFollowing = false }
                    }
                }
                .onChange(of: visibleEntries.count) { _, _ in
                    guard environment.preferences.consoleLogScrollToBottom, isFollowing else { return }
                    scrollToBottom(proxy)
                }
                .onAppear {
                    guard environment.preferences.consoleLogScrollToBottom else { return }
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private static let bottomAnchor = "console-log-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private func toggle(_ id: UInt64) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    private var visibleEntries: [ConsoleLogEntry] {
        switch filter {
        case .all: return environment.consoleLog.allEntries
        case .data: return environment.consoleLog.entries(tag: .data)
        case .meta: return environment.consoleLog.entries(tag: .meta)
        }
    }

    private func copyAll() {
        let text = visibleEntries.map(Self.formatted).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func formatted(_ entry: ConsoleLogEntry) -> String {
        let timestamp = timeFormatter.string(from: entry.timestamp)
        let tag = entry.tag == .data ? "[data]" : "[meta]"
        var line = "\(timestamp) \(tag)"
        if let database = entry.database { line += "  \(database)" }
        if let duration = entry.durationMilliseconds { line += "  \(duration) ms" }
        if let rows = entry.returnedRowCount { line += "  \(rows) 行" }
        if let code = entry.errorCode { line += "  ✗ \(code)" }
        return line + "\n" + entry.sql
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// Console Log 类别过滤。
enum ConsoleLogFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case data
    case meta

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .data: return "仅数据语句"
        case .meta: return "仅元数据"
        }
    }
}

/// 一条 Console Log。
private struct ConsoleLogRow: View {

    let entry: ConsoleLogEntry
    let isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(entry.tag == .data ? "[data]" : "[meta]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(entry.tag == .data ? .blue : .secondary)
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let database = entry.database {
                    Text(database).foregroundStyle(.tertiary)
                }
                if let duration = entry.durationMilliseconds {
                    Text("\(duration) ms").monospacedDigit().foregroundStyle(.secondary)
                }
                if let rows = entry.returnedRowCount {
                    Text("\(rows) 行").foregroundStyle(.secondary)
                }
                if let affected = entry.affectedRows {
                    Text("影响 \(affected) 行").foregroundStyle(.secondary)
                }
                if let code = entry.errorCode {
                    Text("✗ \(code)").foregroundStyle(.red)
                }
                if entry.isCancelled {
                    Text("已取消").foregroundStyle(.orange)
                }
                Spacer()
            }
            Text(entry.sql)
                .font(.system(.body, design: .monospaced))
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
            if isExpanded, let errorMessage = entry.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
