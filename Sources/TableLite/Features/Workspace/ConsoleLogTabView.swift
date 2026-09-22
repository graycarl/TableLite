import SwiftUI
import AppKit

/// Console Log 标签（`specs/06-query-editor.md` §6）。
///
/// 数据来自 `AppEnvironment.consoleLog`；本阶段实现按类别过滤、复制全部与清空。
struct ConsoleLogTabView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var filter: ConsoleLogFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
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

            Button("复制") { copyAll() }
                .disabled(visibleEntries.isEmpty)
            Button("清空") { environment.consoleLog.clear() }
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
            List(visibleEntries) { entry in
                ConsoleLogRow(entry: entry)
            }
            .listStyle(.inset)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
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
                if let code = entry.errorCode {
                    Text("✗ \(code)").foregroundStyle(.red)
                }
                Spacer()
            }
            Text(entry.sql)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3)
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
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
