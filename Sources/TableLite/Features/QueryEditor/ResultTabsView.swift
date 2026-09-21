import AppKit
import SwiftUI

// MARK: - 结果标签栏 + 结果区
//
// 标签文字：`结果 N` / `完成` / `错误` / `只读拦截`；超过 24 个折叠成前 23 + `…` 下拉。
// 右键：关闭 / 关闭其他 / 复制这条语句 / 复制结果。
// 见 specs/06-query-editor.md §4、docs/tech-designs/10-query-editor.md §6。
//
// 「关闭结果标签」是纯展示层动作：ViewModel 的 `results` 不提供删除接口，
// 这里用 `closedResultIDs` 记录被关闭的结果 id（新一轮执行重置）。

struct ResultTabsView: View {
    @ObservedObject var model: QueryTabViewModel
    /// 右键「导出结果…」。为 nil 或非结果集时不显示该菜单项（向后兼容的默认值）。
    var onExportResult: ((QueryResult) -> Void)? = nil

    @EnvironmentObject private var toasts: ToastCenter

    @State private var closedResultIDs: Set<Int> = []
    @State private var previousResultIDs: [Int] = []

    /// 超过该数量才折叠。
    private static let foldThreshold = 24
    /// 折叠时直接显示的数量。
    private static let directLimit = 23

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .onChange(of: model.results.map(\.id)) { _, newValue in
            // 新一轮执行结果 id 从 0 重新分配；旧结果被替换时清空关闭状态。
            if newValue.count <= previousResultIDs.count, newValue.first != previousResultIDs.first {
                closedResultIDs.removeAll()
            }
            if newValue.isEmpty {
                closedResultIDs.removeAll()
            }
            previousResultIDs = newValue
        }
        .onChange(of: model.isExecuting) { _, isExecuting in
            if isExecuting { closedResultIDs.removeAll() }
        }
    }

    // MARK: 标签栏

    private var visibleResults: [QueryResult] {
        model.results.filter { !closedResultIDs.contains($0.id) }
    }

    private var activeResult: QueryResult? {
        let results = model.results
        if results.indices.contains(model.activeResultIndex) {
            let candidate = results[model.activeResultIndex]
            if !closedResultIDs.contains(candidate.id) { return candidate }
        }
        return visibleResults.first
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(directResults) { result in
                        tabButton(result)
                    }
                    if visibleResults.count > Self.foldThreshold {
                        overflowMenu
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 8)
            Text(model.statusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 10)
                .lineLimit(1)
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var directResults: [QueryResult] {
        if visibleResults.count > Self.foldThreshold {
            return Array(visibleResults.prefix(Self.directLimit))
        }
        return visibleResults
    }

    private var overflowResults: [QueryResult] {
        Array(visibleResults.dropFirst(Self.directLimit))
    }

    private func tabButton(_ result: QueryResult) -> some View {
        let isActive = activeResult?.id == result.id
        return Button {
            select(result)
        } label: {
            HStack(spacing: 4) {
                if result.isFailure {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                }
                Text(result.title)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(result.isFailure ? Color.red : Color.primary)
        .contextMenu { contextMenu(result) }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(overflowResults) { result in
                Button(result.title) { select(result) }
            }
        } label: {
            Text("…")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: 结果内容

    @ViewBuilder
    private var content: some View {
        if let result = activeResult {
            ResultGridView(result: result)
        } else if model.isExecuting {
            ProgressView("正在执行…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("执行 SQL 后可在这里查看结果")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 动作

    private func select(_ result: QueryResult) {
        guard let index = model.results.firstIndex(where: { $0.id == result.id }) else { return }
        model.activeResultIndex = index
    }

    private func close(_ result: QueryResult) {
        closedResultIDs.insert(result.id)
    }

    private func closeOthers(_ result: QueryResult) {
        closedResultIDs = Set(model.results.map(\.id).filter { $0 != result.id })
    }

    @ViewBuilder
    private func contextMenu(_ result: QueryResult) -> some View {
        Button("关闭") { close(result) }
        Button("关闭其他") { closeOthers(result) }
        Divider()
        Button("复制这条语句") { copy(result.statement, label: "语句") }
        Button("复制结果") { copy(text(for: result), label: "结果") }
        if let onExportResult, result.rowCount != nil {
            Divider()
            Button("导出结果…") { onExportResult(result) }
        }
    }

    private func copy(_ text: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        toasts.show("已复制\(label)", actionTitle: nil, action: nil)
    }

    private func text(for result: QueryResult) -> String {
        switch result.kind {
        case .rows(let set):
            var lines = [set.header.columns.map(\.name).joined(separator: "\t")]
            for row in set.rows {
                lines.append(row.map { $0.isNull ? "NULL" : $0.displayText }.joined(separator: "\t"))
            }
            return lines.joined(separator: "\n")
        case .affected(let header):
            return "影响 \(header.affectedRows) 行"
        case .error(let error):
            return "[错误 \(error.code)] SQLSTATE \(error.sqlState)\n\(error.message)"
        case .rejected(let reason):
            return "只读拦截：\(reason)"
        }
    }
}

private extension QueryResult {
    var isFailure: Bool {
        switch kind {
        case .error, .rejected:
            return true
        case .rows, .affected:
            return false
        }
    }
}
