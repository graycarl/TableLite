import SwiftUI
import AppKit

/// 查询历史标签（`specs/06-query-editor.md` §5）。
///
/// 本阶段实现只读列表 + 搜索 + 清空。双击插入当前查询标签、复制、在新标签打开等
/// 需要 SQL 编辑器的能力，留到 W4/W7。
struct HistoryTabView: View {

    let session: ConnectionSession

    @Environment(AppEnvironment.self) private var environment
    @State private var entries: [QueryHistoryEntry] = []
    @State private var search = ""
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task(id: search) { await load() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer()
            Text("\(entries.count) 条")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("清空历史") { clear() }
                .disabled(entries.isEmpty)
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
            List(entries) { entry in
                HistoryRow(entry: entry)
            }
            .listStyle(.inset)
        }
    }

    private func load() async {
        do {
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            entries = try await environment.history.recent(
                connectionID: session.id,
                search: trimmed.isEmpty ? nil : trimmed,
                limit: 200
            )
            loadError = nil
        } catch {
            loadError = "查询历史不可用：\(error)"
        }
    }

    private func clear() {
        Task {
            try? await environment.history.clear(connectionID: session.id)
            await load()
        }
    }
}

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
