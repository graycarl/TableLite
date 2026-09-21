import Combine
import SwiftUI
import os

// MARK: - 表数据标签
//
// 数据网格（AppKit）+ 右侧字段栏（SwiftUI）+ 快速查看 + 预览 / 提交面板。
//
// 契约：工作区外壳以 `TableDataTabView(session:tab:environment:)` 创建，
// 这里用 `@StateObject` 持有 `TableDataViewModel` 并在 `.onAppear` 里挂到 `tab`。
//
// 设计依据：docs/tech-designs/06-ui-layer.md §4 §7、07-data-grid.md、14-row-inspector.md、
// 08-pending-changes.md；specs/02-workspace.md、03-data-browsing.md、04-data-editing.md。
struct TableDataTabView: View {

    @ObservedObject var session: ConnectionSession
    let tab: Tab
    let environment: AppEnvironment

    /// 过滤器横条插槽（Wave 5 注入）。默认空；真实横条由本视图内部的 `FilterBarView` 提供。
    var filterBar: AnyView = AnyView(EmptyView())

    @StateObject private var model: TableDataViewModel
    @ObservedObject private var preferences: PreferencesStore
    /// 过滤器横条可见性 / 焦点请求，与状态栏共享（按标签 id 分桶）。
    @ObservedObject private var filterPanel: FilterPanelState
    @EnvironmentObject private var toastCenter: ToastCenter

    @State private var focusRequest: String?
    @State private var quickLookController = QuickLookPanelController()
    @State private var previewStatements: [PendingSQLStatement] = []
    @State private var showsPreview = false
    @State private var commitFailure: CommitFailurePresentation?
    @State private var showsDiscardConfirm = false
    @State private var inspectorDragStart: Double?
    /// 网格右键「导出选中行…」的 sheet（specs/08 §1）。
    @State private var exportRequest: ExportSheetRequest?

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    init(session: ConnectionSession,
         tab: Tab,
         environment: AppEnvironment,
         filterBar: AnyView = AnyView(EmptyView())) {
        self.session = session
        self.tab = tab
        self.environment = environment
        self.filterBar = filterBar
        self._preferences = ObservedObject(wrappedValue: environment.preferences)
        self._filterPanel = ObservedObject(wrappedValue: FilterPanelCoordinator.shared.state(for: tab.id))

        let ref: TableRef
        if case .tableData(let value) = tab.kind {
            ref = value
        } else {
            ref = TableRef(database: "", table: "")
        }
        let prefs = environment.preferences
        let tableState = environment.tableState
        _model = StateObject(wrappedValue: TableDataViewModel(
            connectionID: session.id,
            ref: ref,
            session: session.mysql,
            meta: session.meta,
            loader: session.loader,
            preferences: prefs,
            tableState: tableState,
            isReadOnly: session.isReadOnly,
            onPendingChangeStateChanged: { [weak tab] isEmpty in
                tab?.hasPendingChanges = !isEmpty
            }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if filterPanel.isFilterBarVisible {
                FilterBarView(
                    model: model,
                    isVisible: $filterPanel.isFilterBarVisible,
                    focusToken: filterPanel.focusToken,
                    focusConditionID: $filterPanel.focusConditionID,
                    literalizerProvider: { await session.mysql.literalizer() }
                )
            }
            HStack(spacing: 0) {
                grid
                if preferences.showRowInspector {
                    inspectorDivider
                    RowInspectorView(model: model,
                                     preferences: preferences,
                                     focusRequest: $focusRequest,
                                     onQuickLook: presentQuickLook)
                        .frame(width: CGFloat(preferences.rowInspectorWidth))
                        .background(Color(nsColor: .controlBackgroundColor))
                }
            }
        }
        .onAppear {
            tab.tableData = model
            tab.reloadAfterReconnect = {
                await model.reload()
            }
        }
        .task {
            await model.load()
            await model.loadFullValuesIfNeeded()
        }
        .onChange(of: model.focusedRow) { _, _ in
            Task { await model.loadFullValuesIfNeeded() }
        }
        .sheet(isPresented: $showsPreview) {
            PendingPreviewSheet(
                statements: previewStatements,
                onOpenInQuery: openStatementsInQuery,
                onDiscard: requestDiscard,
                onSubmit: submitChanges
            )
        }
        .sheet(item: $commitFailure) { presentation in
            CommitErrorSheet(
                failure: presentation.failure,
                onDiscardAll: { Task { await model.discardAll() } },
                onClose: {}
            )
        }
        .sheet(item: $exportRequest) { request in
            ExportPanelView(source: request.source,
                            session: session,
                            fileSystem: environment.fileSystem,
                            preferences: environment.preferences)
        }
        .confirmationDialog("放弃未提交的修改？",
                            isPresented: $showsDiscardConfirm,
                            titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                Task { await model.discardAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前标签有 \(model.pendingStats.total) 处未提交的修改。")
        }
        // 只读模式实时生效：菜单 / 连接配置切换后重算可编辑性（specs/09-readonly-mode.md §6）。
        .onChange(of: session.isReadOnly) { _, newValue in
            model.setReadOnly(newValue)
        }
        // 提交期间锁住整个标签内容（specs/12-feedback.md §1、docs/08-pending-changes.md §5）。
        .overlay {
            if model.isCommitting {
                CommitLockOverlay(progress: model.commitProgress)
            }
        }
    }

    // MARK: 网格

    private var grid: some View {
        DataGridView(
            model: model,
            preferences: preferences,
            failedRow: commitFailure?.row,
            onQuickLook: presentQuickLook,
            onBeginEdit: beginEditing,
            onForeignKeyJump: jumpToForeignKey,
            onToast: { message in toastCenter.show(message) },
            onFilterByValue: filterByValue,
            onFilterByColumn: filterByColumn,
            onExportSelected: exportSelectedRows,
            onRequestPreview: requestPreview,
            onRequestCommit: submitChanges,
            onRequestDiscard: requestDiscard,
            literalizerProvider: { await session.mysql.literalizer() }
        )
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var inspectorDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let start = inspectorDragStart ?? preferences.rowInspectorWidth
                                if inspectorDragStart == nil { inspectorDragStart = start }
                                let newWidth = start - Double(value.translation.width)
                                preferences.rowInspectorWidth = min(max(newWidth, 260), 560)
                            }
                            .onEnded { _ in inspectorDragStart = nil }
                    )
            )
    }

    // MARK: 交互

    /// 右键「导出选中行…」：把当前页已加载的选中行作为内存行导出。
    ///
    /// `TableDataViewModel` 未暴露行定位键，按任务约定走内存行路径（`locators: []` +
    /// `fallbackRows`），不改 Core。
    private func exportSelectedRows(_ identities: Set<RowIdentity>) {
        guard let structure = model.structure else { return }
        let rows = model.displayRows
            .filter { identities.contains($0.identity) }
            .map(\.values)
        guard !rows.isEmpty else { return }
        exportRequest = ExportSheetRequest(source: .selectedRows(ref: model.ref,
                                                                 structure: structure,
                                                                 locators: [],
                                                                 fallbackRows: rows))
    }

    private func beginEditing(row: RowIdentity, column: String) {
        model.focusedRow = row
        model.focusedColumn = column
        preferences.showRowInspector = true
        focusRequest = column
    }

    private func presentQuickLook(row: RowIdentity, column: String) {
        guard let tableColumn = model.allColumns.first(where: { $0.name == column }) else { return }
        let value = model.currentValue(row: row, column: column)
        let needsLoad = model.isTruncated(row: row, column: column)
            && model.fullValue(row: row, column: column) == nil

        quickLookController.show(
            title: "\(model.ref.table).\(column)",
            kind: tableColumn.kind,
            value: value,
            isLoading: needsLoad,
            error: nil
        )

        guard needsLoad else { return }
        Task {
            await model.loadFullValue(row: row, column: column)
            let loaded = model.fullValue(row: row, column: column) ?? value
            let error = model.fullValueError
            quickLookController.update(value: loaded, isLoading: false, error: error)
        }
    }

    private func filterByValue(column: String, value: CellValue, exclude: Bool) {
        // 右键单元格 → 按此值筛选 / 排除此值：立即应用（specs/05 §1）。
        var next = model.filter
        if next.useRawSQL {
            next = FilterPanelLogic.switchingToConditions(next)
        }
        let condition = FilterCondition(column: column,
                                        op: exclude ? .notEqual : .equal,
                                        value: value.displayText)
        next.conditions.append(condition)
        filterPanel.isFilterBarVisible = true
        Task { await model.applyFilter(next) }
    }

    /// 右键列头 → 按此列筛选：加一条等于条件但值留空并聚焦（specs/05 §1）。
    private func filterByColumn(_ column: String) {
        var next = model.filter
        if next.useRawSQL {
            next = FilterPanelLogic.switchingToConditions(next)
        }
        let condition = FilterCondition(column: column, op: .equal, value: "")
        next.conditions.append(condition)
        model.filter = next
        filterPanel.isFilterBarVisible = true
        filterPanel.focusConditionID = condition.id
        filterPanel.focusToken += 1
    }

    private func jumpToForeignKey(row: RowIdentity, column: String, value: CellValue) {
        guard let structure = model.structure,
              let constraint = structure.foreignKeys.first(where: { $0.columns.contains(column) }) else {
            return
        }
        let ref = TableRef(database: constraint.referencedDatabase, table: constraint.referencedTable)

        // 被引用列：外键列在约束里的下标对应 referencedColumns 的同一下标。
        let referencesIndex = constraint.columns.firstIndex(of: column)
        let referencedColumn: String?
        if let referencesIndex, referencesIndex < constraint.referencedColumns.count {
            referencedColumn = constraint.referencedColumns[referencesIndex]
        } else {
            referencedColumn = constraint.referencedColumns.first
        }
        guard let referencedColumn else {
            toastCenter.show("外键目标表缺少可用的主键列")
            logger.error("外键跳转失败：约束 \(constraint.name, privacy: .public) 没有 referencedColumns")
            return
        }

        let condition = FilterCondition(column: referencedColumn,
                                        op: .equal,
                                        value: value.displayText)
        let desired = FilterSet(conditions: [condition])

        // 新标签的 ViewModel 在 `onAppear` 里才装配；先写入表的呈现状态，
        // `TableDataViewModel.init` 会读取 `saved.filter`，从而在 `load()` 前完成预置。
        if preferences.rememberTableFilters {
            var state = environment.tableState.state(connectionID: session.id, table: ref)
            state.filter = desired
            environment.tableState.save(state, connectionID: session.id, table: ref)
            session.openTableData(ref, forceNew: true)
        } else {
            let newTab = session.openTableData(ref, forceNew: true)
            // 该偏好关闭时无法在加载前预置，退化为「打开后应用」。
            Task { @MainActor in
                for _ in 0..<300 {
                    if let model = newTab.tableData as? TableDataViewModel {
                        await model.applyFilter(desired)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                // TODO(Wave 5b)：偏好关闭时无法保证在首次加载前预置过滤条件。
                toastCenter.show("已打开 \(ref.table)，但未能自动应用外键过滤条件")
            }
        }
    }

    // MARK: 预览 / 提交 / 放弃

    private func requestPreview() {
        Task {
            let statements = await model.previewStatements()
            guard !statements.isEmpty else { return }
            previewStatements = statements
            showsPreview = true
        }
    }

    private func openStatementsInQuery(_ statements: [PendingSQLStatement]) {
        let sql = statements.map(\.text).joined(separator: "\n\n")
        session.newQueryTab(initialSQL: sql)
        showsPreview = false
    }

    private func submitChanges() {
        Task {
            let statements = await model.previewStatements()
            do {
                let outcome = try await model.commit()
                let components = outcome.elapsed.components
                let milliseconds = Double(components.seconds) * 1000
                    + Double(components.attoseconds) / 1e15
                let formatted = String(format: "%.0f ms", milliseconds)
                toastCenter.show("已提交 \(outcome.executedCount) 处修改 · \(formatted)")
            } catch let failure as CommitFailure {
                let index = failure.statementIndex - 1
                let row = statements.indices.contains(index) ? statements[index].identity : nil
                commitFailure = CommitFailurePresentation(failure: failure, row: row)
            } catch {
                logger.error("提交失败：\(String(describing: error), privacy: .public)")
                toastCenter.show("提交失败：\(String(describing: error))")
            }
        }
    }

    private func requestDiscard() {
        let stats = model.pendingStats
        if stats.total > 5 || stats.inserts > 0 || stats.deletes > 0 {
            showsDiscardConfirm = true
        } else {
            Task { await model.discardAll() }
        }
    }
}

/// `.sheet(item:)` 需要 `Identifiable`；`CommitFailure` 本身不携带 id。
struct CommitFailurePresentation: Identifiable {
    let id = UUID()
    let failure: CommitFailure
    /// 失败语句对应的行身份（用于网格红色高亮）。
    let row: RowIdentity?
}

// MARK: - 提交锁定遮罩

/// 提交期间盖住标签内容，阻止继续编辑；同时显示「正在提交 3/7…」。
private struct CommitLockOverlay: View {

    let progress: CommitProgress?

    var body: some View {
        ZStack {
            Color.black.opacity(0.06)
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text(progress.map { "正在提交 \($0.completed)/\($0.total)…" } ?? "正在提交…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .contentShape(Rectangle())
        .ignoresSafeArea()
    }
}
