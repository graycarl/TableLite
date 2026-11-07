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
    /// 运行开始后短暂延迟才允许点「停止」，避免双击「执行」的第二次点击把查询取消。
    @State private var stopArmed = false

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColor.content)
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
                    .background(AppColor.content)

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
        .task(id: viewModel.isRunning) {
            guard viewModel.isRunning else {
                stopArmed = false
                return
            }
            stopArmed = false
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { stopArmed = true }
        }
    }

    // MARK: 工具栏

    private func toolbar(_ viewModel: QueryEditorViewModel) -> some View {
        HStack(spacing: AppSpacing.xs) {
            if viewModel.isRunning {
                Button {
                    viewModel.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .help("停止当前查询（⌘.）")
                .accessibilityIdentifier("editor.stop")
                .disabled(!stopArmed || viewModel.isStopping)
            } else {
                HStack(spacing: 0) {
                    Button {
                        viewModel.executeDefault()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                            Text("执行")
                            Text("⌘↩")
                                .font(.system(size: 9.5))
                                .opacity(0.75)
                        }
                        .padding(.horizontal, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("\(viewModel.defaultScope.displayName)（⌘↩）")
                    .accessibilityIdentifier("editor.run")

                    Menu {
                        Button("执行全部") { viewModel.executeAll() }
                            .accessibilityIdentifier("editor.run-all")

                        Divider()

                        Toggle("默认执行当前语句", isOn: Binding(
                            get: { environment.preferences.defaultExecutionScope == .currentStatement },
                            set: { if $0 { environment.preferences.defaultExecutionScope = .currentStatement } }
                        ))
                        Toggle("默认执行全部", isOn: Binding(
                            get: { environment.preferences.defaultExecutionScope == .allStatements },
                            set: { if $0 { environment.preferences.defaultExecutionScope = .allStatements } }
                        ))
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("执行范围：\(viewModel.defaultScope.displayName)")
                    .accessibilityLabel("执行范围")
                    .accessibilityValue(viewModel.defaultScope.displayName)
                    .accessibilityIdentifier("editor.scope")
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.m))
                .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
            }

            Spacer()

            Menu {
                Button("打开…") { openScript() }
                    .accessibilityIdentifier("editor.open")
                Button("另存为…") { _ = viewModel.saveScriptAs() }
                    .accessibilityIdentifier("editor.save")
                Divider()
                Button("清空") { viewModel.textChanged("") }
                    .disabled(viewModel.text.isEmpty)
                    .accessibilityIdentifier("editor.clear")
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("更多操作")
            .accessibilityIdentifier("editor.more")
        }
        .padding(.horizontal, AppSpacing.m)
        .padding(.vertical, AppSpacing.xs)
        .background(AppColor.bar)
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
            if let draft = WorkspaceStatusText.draftStatus(
                hasFile: viewModel.hasFile,
                isDirty: viewModel.isDirty,
                autoSaveEnabled: environment.preferences.autoSaveDraft
            ) {
                Text(draft.text)
                    .foregroundStyle(draft.isWarning ? Color.orange : Color.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 26)
        .background(AppColor.bar)
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
            .background(AppColor.bar)
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
