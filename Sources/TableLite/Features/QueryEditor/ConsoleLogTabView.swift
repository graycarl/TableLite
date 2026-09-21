import AppKit
import SwiftUI
import os

// MARK: - Console Log
//
// 过滤器（全部 / 仅 data / 仅 meta）+ 复制 + 清空；列表展开看完整 SQL 与结果概要；
// 自动跟随底部，用户上滚后暂停并显示「回到底部」。
// 见 specs/06-query-editor.md §6、docs/tech-designs/02-persistence.md §5。
//
// 跨文件契约：工作区外壳按 `ConsoleLogTabView(session:tab:environment:)` 装配。

struct ConsoleLogTabView: View {
    let session: ConnectionSession
    let tab: Tab
    let environment: AppEnvironment

    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var model: ConsoleLogViewModel

    @State private var follow = true
    @State private var expanded: Set<UInt64> = []
    @State private var showingClearConfirm = false

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    init(session: ConnectionSession, tab: Tab, environment: AppEnvironment) {
        self.session = session
        self.tab = tab
        self.environment = environment
        _model = StateObject(wrappedValue: ConsoleLogViewModel(store: environment.consoleLog))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .onAppear { follow = environment.preferences.consoleLogAutoScroll }
        .alert("清空 Console Log", isPresented: $showingClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) {
                model.clear()
                expanded.removeAll()
                toasts.show("已清空 Console Log", actionTitle: nil, action: nil)
            }
        } message: {
            Text("将删除内存中的全部日志记录，无法撤销。")
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.filter) {
                ForEach(ConsoleLogViewModel.Filter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField("搜索 SQL", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Spacer()

            Text("\(model.entries.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                copyAll()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }

            Button {
                showingClearConfirm = true
            } label: {
                Label("清空", systemImage: "trash")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: 列表

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.entries) { entry in
                        entryView(entry)
                            .id(entry.id)
                    }
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height < 40
            } action: { _, atBottom in
                follow = atBottom
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: model.entries.count) { _, _ in
                guard follow else { return }
                scrollToBottom(proxy, animated: true)
            }
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button {
                        follow = true
                        scrollToBottom(proxy, animated: true)
                    } label: {
                        Label("回到底部", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(12)
                }
            }
        }
    }

    private func entryView(_ entry: ConsoleLogStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                Text(entry.category == .data ? "[data]" : "[meta]")
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.category == .data ? Color.blue : Color.secondary)

                Text(Self.timestampText(entry.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let database = entry.database, !database.isEmpty {
                    Text(database)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let code = entry.errorCode {
                    Text("✗ \(code)")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(QueryTabLogic.elapsedText(entry.elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if expanded.contains(entry.id) {
                Text(entry.sql)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
                summary(entry)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { toggle(entry.id) }
        .contextMenu {
            Button("复制这条语句") { copy(entry.sql) }
        }
    }

    @ViewBuilder
    private func summary(_ entry: ConsoleLogStore.Entry) -> some View {
        Text(summaryText(entry))
            .font(.caption)
            .foregroundStyle(entry.errorCode == nil ? Color.secondary : Color.red)
    }

    private func summaryText(_ entry: ConsoleLogStore.Entry) -> String {
        if let code = entry.errorCode {
            var text = "错误 \(code)"
            if let message = entry.errorMessage, !message.isEmpty {
                text += "：\(message.replacingOccurrences(of: "\n", with: " "))"
            }
            return text
        }
        var parts: [String] = []
        if let affected = entry.affectedRows {
            parts.append("影响 \(QueryTabLogic.grouped(affected)) 行")
        } else if let rows = entry.rowCount {
            parts.append("返回 \(QueryTabLogic.grouped(rows)) 行")
        }
        parts.append("耗时 \(QueryTabLogic.elapsedText(entry.elapsed))")
        return parts.joined(separator: " · ")
    }

    // MARK: 动作

    private func toggle(_ id: UInt64) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = model.entries.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        toasts.show("已复制", actionTitle: nil, action: nil)
    }

    private func copyAll() {
        copy(model.textDump)
        toasts.show("已复制 \(model.entries.count) 条", actionTitle: nil, action: nil)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func timestampText(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}
