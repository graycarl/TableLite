import SwiftUI
import AppKit

/// SQL 编辑器标签的内容视图（`specs/06-query-editor.md` §1）。
///
/// 组合：工具栏 → 编辑器 → 可拖拽分隔条 → 结果区。
/// ViewModel 装配后挂到 `tab.content`，供 `WorkspaceView` 接菜单命令（执行 / 停止 / 查找）。
struct QueryEditorView: View {

    let session: ConnectionSession
    let tab: Tab

    @Environment(AppEnvironment.self) private var environment
    @Environment(ExportRequestCenter.self) private var exportCenter
    @State private var viewModel: QueryEditorViewModel?
    @State private var quickLook: QuickLookPanelController?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear(perform: startIfNeeded)
        .onDisappear(perform: teardown)
    }

    // MARK: 装配

    private func startIfNeeded() {
        guard viewModel == nil else { return }
        let model = QueryEditorViewModel(
            session: session,
            tab: tab,
            preferences: environment.preferences,
            drafts: environment.drafts,
            clock: environment.clock
        )
        viewModel = model
        tab.content = model
        Task { await model.start() }
    }

    private func teardown() {
        guard let viewModel else { return }
        viewModel.stopInFlight()
        if tab.content === viewModel {
            tab.content = nil
        }
    }

    // MARK: 主体

    private func content(_ viewModel: QueryEditorViewModel) -> some View {
        VStack(spacing: 0) {
            toolbar(viewModel)
            if session.isReadOnly {
                readOnlyBanner
            }
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    SQLTextView(
                        text: Binding(
                            get: { viewModel.text },
                            set: { viewModel.textChanged($0) }
                        ),
                        isEditable: true,
                        fontName: environment.preferences.editorFontName,
                        fontSize: Double(environment.preferences.editorFontSize),
                        indentWidth: environment.preferences.indentWidth,
                        showLineNumbers: environment.preferences.showLineNumbers,
                        highlightCurrentStatement: environment.preferences.highlightCurrentStatement,
                        findRequestToken: viewModel.findRequestToken,
                        command: viewModel.editorCommand,
                        onSelectionChange: { viewModel.selectionChanged($0) }
                    )
                    .frame(height: editorHeight(in: geometry.size.height))
                    .background(Color(nsColor: .textBackgroundColor))

                    VerticalResizeHandle { delta in
                        adjustSplit(delta: delta, totalHeight: geometry.size.height)
                    }

                    QueryResultAreaView(
                        viewModel: viewModel,
                        displayContext: displayContext,
                        fontSize: Double(environment.preferences.gridFontSize),
                        alternateRowColors: environment.preferences.alternateRowColors,
                        onQuickLook: { presentQuickLook($0) },
                        onExportResult: { result in
                            exportCenter.present(
                                .queryResult(sql: result.statementText, description: result.title)
                            )
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    statusBar(viewModel)
                }
            }
        }
        .overlay(alignment: .top) { noticeOverlay(viewModel) }
        .overlay(alignment: .topTrailing) { largeResultOverlay(viewModel) }
    }

    // MARK: 工具栏

    private func toolbar(_ viewModel: QueryEditorViewModel) -> some View {
        HStack(spacing: AppSpacing.xs) {
            Button {
                viewModel.executeDefault()
            } label: {
                Label("执行", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("\(viewModel.defaultScope.displayName)（⌘↩）")
            .disabled(viewModel.isRunning)

            Menu {
                Button("执行当前语句") { environment.preferences.defaultExecutionScope = .currentStatement }
                Button("执行全部") { environment.preferences.defaultExecutionScope = .allStatements }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("默认执行范围：\(viewModel.defaultScope.displayName)")

            Button {
                viewModel.executeAll()
            } label: {
                Label("执行全部", systemImage: "forward.end.fill")
            }
            .buttonStyle(.subtle)
            .help("执行全部（⇧⌘↩）")
            .disabled(viewModel.isRunning)

            Button {
                viewModel.stop()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.subtle)
            .help("停止（⌘.）")
            .disabled(!viewModel.isRunning || viewModel.isStopping)

            Divider().frame(height: 18)

            Button("打开") { openScript() }
                .buttonStyle(.subtle)
            Button("另存为") { _ = viewModel.saveScriptAs() }
                .buttonStyle(.subtle)

            Spacer()

            if !viewModel.text.isEmpty {
                Button("清空") { viewModel.textChanged("") }
                    .buttonStyle(.subtle)
            }
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, AppSpacing.xs)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var readOnlyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption)
            Text("只读模式：写操作已被禁用")
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .foregroundStyle(.orange)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: 状态栏

    private func statusBar(_ viewModel: QueryEditorViewModel) -> some View {
        HStack(spacing: 8) {
            if viewModel.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("正在执行… 已接收 \(viewModel.receivedRowCount) 行（\(ByteSize.format(viewModel.receivedByteCount))）（\(elapsedSeconds(viewModel)) 秒）")
                    .monospacedDigit()
            } else if viewModel.executedStatementCount > 0 {
                Text(doneSummary(viewModel))
                    .monospacedDigit()
            } else {
                Text("就绪")
                    .foregroundStyle(.secondary)
            }
            if viewModel.showsLargeResultHint {
                Text("结果较大，可随时停止")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if viewModel.isDirty {
                Text(viewModel.hasFile ? "未保存" : "草稿已自动保存")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func doneSummary(_ viewModel: QueryEditorViewModel) -> String {
        WorkspaceStatusText.querySummary(
            executedStatementCount: viewModel.executedStatementCount,
            elapsedMilliseconds: viewModel.elapsedMilliseconds,
            totalReturnedRows: viewModel.totalReturnedRows
        ) ?? "就绪"
    }

    private func elapsedSeconds(_ viewModel: QueryEditorViewModel) -> String {
        String(format: "%.1f", Double(viewModel.elapsedMilliseconds) / 1000)
    }

    @ViewBuilder
    private func noticeOverlay(_ viewModel: QueryEditorViewModel) -> some View {
        if let notice = viewModel.notice {
            Text(notice)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 48)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func largeResultOverlay(_ viewModel: QueryEditorViewModel) -> some View {
        if viewModel.isRunning, viewModel.showsLargeResultHint {
            Button("停止") { viewModel.stop() }
                .controlSize(.small)
                .padding(10)
        }
    }

    // MARK: 分隔条

    private func editorHeight(in totalHeight: CGFloat) -> CGFloat {
        let ratio = environment.preferences.editorResultSplitRatio
        let minEditor: CGFloat = 100
        let minResult: CGFloat = 120
        let available = max(0, totalHeight - 26)
        let proposed = available * ratio
        return min(max(proposed, minEditor), max(minEditor, available - minResult))
    }

    private func adjustSplit(delta: CGFloat, totalHeight: CGFloat) {
        let available = max(1, totalHeight - 26)
        let ratio = environment.preferences.editorResultSplitRatio + Double(delta / available)
        environment.preferences.editorResultSplitRatio = ratio
    }

    // MARK: 脚本文件

    private func openScript() {
        guard let (url, text) = ScriptFileController.openPanel() else { return }
        // 明确要求：打开到**新的**查询标签（`specs/06-query-editor.md` §7）。
        let newTab = session.newQueryTab()
        newTab.filePath = url.path
        newTab.customTitle = url.lastPathComponent
        newTab.initialSQL = text
    }

    // MARK: 快速查看

    private func presentQuickLook(_ content: QuickLookContent) {
        if quickLook == nil {
            quickLook = QuickLookPanelController()
        }
        quickLook?.present(content)
    }

    // MARK: 偏好投影

    private var displayContext: CellDisplayContext {
        CellDisplayContext(
            nullText: environment.preferences.nullDisplayText,
            tinyintAsCheckbox: environment.preferences.tinyintAsCheckbox
        )
    }
}

// MARK: - 纵向分隔条

/// 编辑区 / 结果区之间的可拖拽分隔条。
struct VerticalResizeHandle: View {

    var onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 40, height: 3)
            )
            .background(.bar)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let delta = value.translation.height - lastTranslation
                        lastTranslation = value.translation.height
                        onDrag(delta)
                    }
                    .onEnded { _ in lastTranslation = 0 }
            )
    }
}
