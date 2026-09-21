import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 查询标签
//
// 工具栏（执行 / 执行全部 / 停止 / 打开 / 另存为）+ 编辑器 + 可拖拽分隔条 + 结果区。
// 见 specs/06-query-editor.md §1–§3、docs/tech-designs/10-query-editor.md §1 §5。
//
// 跨文件契约：工作区外壳按 `QueryTabView(session:tab:environment:)` 装配；
// `QueryTabViewModel` 由本视图用 `@StateObject` 创建，并回填 `tab.query`。

struct QueryTabView: View {
    @ObservedObject var session: ConnectionSession
    let tab: Tab
    let environment: AppEnvironment

    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var model: QueryTabViewModel
    @ObservedObject private var preferences: PreferencesStore

    @State private var splitRatio: Double
    @State private var dragStartRatio: Double?
    /// 结果标签右键「导出结果…」的 sheet（specs/08 §1）。
    @State private var exportRequest: ExportSheetRequest?

    private static let dividerHeight: CGFloat = 6

    init(session: ConnectionSession, tab: Tab, environment: AppEnvironment) {
        self.session = session
        self.tab = tab
        self.environment = environment

        let draftID: UUID
        if case .query(let id) = tab.kind {
            draftID = id
        } else {
            draftID = UUID()
        }

        _model = StateObject(wrappedValue: QueryTabViewModel(
            connectionID: session.id,
            database: session.selectedDatabase,
            session: session.mysql,
            isReadOnly: session.isReadOnly,
            preferences: environment.preferences,
            history: environment.history,
            consoleLog: environment.consoleLog,
            drafts: environment.drafts,
            clock: environment.clock,
            draftID: draftID,
            initialSQL: tab.initialSQL ?? "",
            fileURL: nil
        ))
        _preferences = ObservedObject(wrappedValue: environment.preferences)
        _splitRatio = State(initialValue: environment.preferences.editorSplitRatio)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.isReadOnly {
                readonlyBanner
            }
            GeometryReader { geometry in
                let total = max(geometry.size.height, 1)
                VStack(spacing: 0) {
                    SQLEditorView(
                        text: $model.sql,
                        selectedRange: $model.selectedRange,
                        cursorLocation: $model.cursorLocation,
                        fontName: preferences.editorFontName,
                        fontSize: preferences.editorFontSize,
                        indentWidth: preferences.editorIndentWidth,
                        showLineNumbers: preferences.editorShowLineNumbers,
                        highlightCurrentStatement: preferences.editorHighlightCurrentStatement,
                        isEditable: true,
                        onExecute: { runCurrent() },
                        onExecuteAll: { runAll() },
                        onStop: { model.stop() }
                    )
                    .frame(height: max(120, (total - Self.dividerHeight) * splitRatio))

                    divider(total: total)

                    ResultTabsView(model: model, onExportResult: exportResult)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .sheet(item: $exportRequest) { request in
            ExportPanelView(source: request.source,
                            session: session,
                            fileSystem: environment.fileSystem,
                            preferences: environment.preferences)
        }
        .onAppear { tab.query = model }
        .task { await model.loadDraft() }
        // 只读模式实时生效（specs/09-readonly-mode.md §6）。
        .onChange(of: session.isReadOnly) { _, newValue in
            model.setReadOnly(newValue)
        }
    }

    // MARK: 导出结果

    /// 结果集标签右键「导出结果…」：原 SQL 剥掉顶层 `LIMIT`，行数取结果集行数。
    /// 非结果集（`完成` / `错误` / `只读拦截`）不提供导出。
    private func exportResult(_ result: QueryResult) {
        guard case .rows(let set) = result.kind else { return }
        exportRequest = ExportSheetRequest(source: .queryResult(
            sql: ExportSQL.stripTopLevelLimit(result.statement).sql,
            columns: set.header.columns,
            knownRowCount: UInt64(set.rows.count)
        ))
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.isExecuting {
                Button {
                    model.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
            } else {
                Button {
                    runCurrent()
                } label: {
                    Label("执行", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button {
                    runAll()
                } label: {
                    Label("执行全部", systemImage: "forward.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            }

            Menu {
                Toggle("⌘↩ 默认执行全部", isOn: Binding(
                    get: { preferences.editorDefaultExecuteAll },
                    set: { preferences.editorDefaultExecuteAll = $0 }
                ))
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
            .help("执行方式")

            Divider().frame(height: 16)

            Button {
                QueryScriptActions.open(session: session, toasts: toasts)
            } label: {
                Label("打开", systemImage: "folder")
            }

            Button {
                QueryScriptActions.saveAs(model: model, tab: tab, toasts: toasts)
            } label: {
                Label("另存为", systemImage: "square.and.arrow.down")
            }

            Spacer(minLength: 8)

            if model.isExecuting {
                progressView
            } else {
                Text(model.statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var readonlyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
            Text("只读模式：写操作已被禁用")
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }

    private var progressView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.progress.rows > 100_000 {
                Text("结果较大，可随时停止")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var progressText: String {
        let progress = model.progress
        let rows = QueryTabLogic.grouped(progress.rows)
        return "正在执行… 已接收 \(rows) 行（\(Self.byteText(progress.bytes))）（\(Self.secondsText(progress.elapsed))）"
    }

    // MARK: 分隔条

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: Self.dividerHeight)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartRatio ?? splitRatio
                        if dragStartRatio == nil { dragStartRatio = splitRatio }
                        let delta = Double(value.translation.height / total)
                        splitRatio = min(0.85, max(0.15, start + delta))
                    }
                    .onEnded { _ in
                        dragStartRatio = nil
                        preferences.editorSplitRatio = splitRatio
                    }
            )
    }

    // MARK: 执行

    private func runCurrent() {
        Task {
            if preferences.editorDefaultExecuteAll {
                await model.executeAll()
            } else {
                await model.executeCurrent()
            }
        }
    }

    private func runAll() {
        Task { await model.executeAll() }
    }

    // MARK: 格式化

    private static func byteText(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? String(format: "%.0f %@", value, units[index])
            : String(format: "%.1f %@", value, units[index])
    }

    private static func secondsText(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1f 秒", seconds)
    }
}

// MARK: - 脚本文件动作

/// 打开 / 另存为 / 查找的共享实现。
///
/// 工具栏按钮与菜单（`@FocusedValue`）走同一条路径，避免两份快捷键与重复逻辑。
/// 见 `specs/02-workspace.md` §8 §9、`docs/tech-designs/06-ui-layer.md` §5。
@MainActor
enum QueryScriptActions {

    static func open(session: ConnectionSession, toasts: ToastCenter) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = scriptContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            session.newQueryTab(initialSQL: content)
        } catch {
            logger.error("打开脚本失败：\(String(describing: error), privacy: .public)")
            toasts.show("打开脚本失败：\(error.localizedDescription)", actionTitle: nil, action: nil)
        }
    }

    static func saveAs(model: QueryTabViewModel, tab: Tab, toasts: ToastCenter) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = scriptContentTypes
        panel.nameFieldStringValue = suggestedFileName(model: model, tab: tab)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.sql.write(to: url, atomically: true, encoding: .utf8)
            model.setFile(url)
            model.markFileSaved()
            tab.customTitle = url.lastPathComponent
            toasts.show("已保存到 \(url.lastPathComponent)", actionTitle: nil, action: nil)
        } catch {
            logger.error("另存为失败：\(String(describing: error), privacy: .public)")
            toasts.show("保存失败：\(error.localizedDescription)", actionTitle: nil, action: nil)
        }
    }

    /// `⌘F`：把查找转给当前第一响应者（SQL 编辑器的 `NSTextView`）。
    /// 查询标签激活时才由工作区上报给菜单（表数据标签的 `⌘F` 仍归状态栏的过滤器）。
    static func find() {
        let item = NSMenuItem()
        // NSFindPanelAction.showFindPanel == 1；`usesFindBar = true` 时 NSTextView 会显示查找条。
        item.tag = 1
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
    }

    private static func suggestedFileName(model: QueryTabViewModel, tab: Tab) -> String {
        if let fileURL = model.fileURL {
            return fileURL.lastPathComponent
        }
        return tab.queryNumber > 0 ? "查询 \(tab.queryNumber).sql" : "查询.sql"
    }

    private static var scriptContentTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let sql = UTType(filenameExtension: "sql") {
            types.append(sql)
        }
        return types
    }
}
