import Foundation
import Observation

/// 一次复制的结果：剪贴板文本 + 轻提示。
public struct CopyResult: Sendable, Equatable {
    public var text: String
    public var notice: String?

    public init(text: String, notice: String? = nil) {
        self.text = text
        self.notice = notice
    }
}

/// 表数据标签（P4 数据网格）的 ViewModel。
///
/// 状态归属见 `docs/tech-designs/06-ui-layer.md` §2：每个标签的 ViewModel 由标签自己持有。
/// 查询一律经 `ConnectionSession.execute`，不直接碰 `MySQLSession`。
///
/// 关键设计：
/// - 列清单来自 `TableDataMetadataProviding`（生产实现走 `MetaRepository` 的
///   `information_schema.COLUMNS`，见 `07-data-grid.md` §3.2）；
/// - 只取前 N 行（`LIMIT rowLimit`，不分页），行数用估算，**绝不自动 `COUNT(*)`**（§3.4、§7）；
/// - 大字段两阶段加载：首屏 `LEFT(col, N)` + 长度列，按需 `selectRowByKey` 取完整值；
///   截断值绝不会写回数据库（`08-pending-changes.md` §9），T8 只读但模型已区分；
/// - 显示条数 / 排序 / 过滤 / 隐藏列状态写回 `Tab`，随 `session.json` 往返。
@MainActor
@Observable
public final class TableDataViewModel {

    // MARK: 标识

    public let session: ConnectionSession
    public let tab: Tab
    public let database: String
    public let table: String

    @ObservationIgnored private let metadataProvider: any TableDataMetadataProviding
    /// `internal`：编辑扩展（另一个文件）需要读写字段栏偏好。
    @ObservationIgnored internal let preferences: Preferences
    @ObservationIgnored internal let clock: Clock

    /// 字段栏自动加载大字段的上限（L12）。
    public static let autoLoadByteLimit = 8 * 1024 * 1024
    /// 复制超过该行数时给轻提示（`specs/03-data-browsing.md` §9）。
    public static let copyNoticeRowThreshold = 100

    // MARK: 元数据

    public private(set) var columns: [ColumnInfo] = []
    public private(set) var tableInfo: TableInfo?
    public private(set) var isView = false
    public private(set) var primaryKeyColumns: [String] = []
    public private(set) var foreignKeyColumns: Set<String> = []
    /// 外键约束明细（用于 `↗` 跳转）。
    public private(set) var foreignKeys: [ForeignKeyInfo] = []
    public private(set) var createStatement: String?
    public private(set) var isMetadataLoaded = false

    public var primaryKeySet: Set<String> { Set(primaryKeyColumns) }

    // MARK: 数据

    public internal(set) var rows: [GridRow] = []
    public private(set) var loadState: TableDataLoadState = .idle
    public private(set) var lastQueryMilliseconds: Int?
    /// 当前加载已用时（毫秒）。加载中每 100 ms 自增，加载结束后停在本次耗时上；
    /// 状态栏据此在 > 1 s 时显示耗时、> 10 s 时附「取消」（`specs/12-feedback.md` §6）。
    public private(set) var elapsedMilliseconds = 0
    public private(set) var rowCountEstimate: RowCountEstimate?
    public private(set) var isCountingExact = false

    // MARK: 查询状态（与 Tab 同步）

    public private(set) var rowLimit: Int
    public private(set) var sortOrders: [SortOrder]
    public private(set) var hiddenColumns: Set<String>
    /// 实际生效（查询用）的过滤状态。
    public private(set) var filter: FilterState?
    /// 过滤器面板编辑中的草稿；点「应用」才复制到 `filter`。
    public internal(set) var filterDraft = FilterState()
    /// 应用失败的错误文案（列不存在 / IN 列表为空 / Raw 含分号）。
    public private(set) var filterError: String?
    /// 出错条件的高亮集合（在面板里标黄）。
    public private(set) var filterErrorConditionIDs: Set<UUID> = []
    /// 列显隐浮层是否打开。
    public private(set) var isColumnFilterPresented = false
    /// 请求面板聚焦的计数器（快捷筛选 / 切 Raw 模式后由视图响应）。
    public internal(set) var filterFocusToken = 0
    /// 需要聚焦的条件 id；nil 表示聚焦 Raw 模式输入框。
    public internal(set) var filterFocusConditionID: UUID?
    public private(set) var columnWidths: [String: Double]

    // MARK: 选择

    public internal(set) var focusedRowID: String?
    public internal(set) var focusedColumn: String?
    public internal(set) var selectedRowIDs: Set<String> = []

    // MARK: 大字段二次加载

    public private(set) var isLoadingFullRow = false
    public private(set) var manualFullLoadRequired = false
    public private(set) var fullRowError: String?
    @ObservationIgnored private var fullRowCache: [String: [String: SQLValue]] = [:]

    // MARK: 复制提示

    public private(set) var copyNotice: String?
    @ObservationIgnored private var copyNoticeTask: Task<Void, Never>?

    // MARK: 编辑与暂存（T9）

    /// 当前标签的变更暂存区（`docs/tech-designs/08-pending-changes.md` §1）。
    public internal(set) var pendingStore = PendingChangeStore()
    /// 新增行（未落库），在网格里显示为绿色行，位于「＋ 插入行」上方。
    public internal(set) var insertionRows: [GridRow] = []
    public internal(set) var isCommitting = false
    public internal(set) var commitCompleted = 0
    public internal(set) var commitTotal = 0
    /// 提交失败详情；非 nil 时弹错误面板。
    public internal(set) var commitFailure: CommitFailure?
    /// 删除行前展示的将执行条件（`specs/04-data-editing.md` §6）；非 nil 时弹确认。
    public internal(set) var pendingDeletion: PendingRowDeletion?
    /// 预览面板的语句快照（与提交走同一条生成路径）。
    public internal(set) var previewStatements: [String] = []
    public internal(set) var isPreviewPresented = false
    public internal(set) var isDiscardConfirmationPresented = false
    /// 字段栏需要聚焦的列（双击单元格 / 新增行时设置）。
    public internal(set) var focusRequestColumn: String?
    public internal(set) var focusRequestToken = 0
    @ObservationIgnored internal var commitTask: Task<Void, Never>?
    @ObservationIgnored internal var cancelCommitRequested = false
    /// 字段栏「查看」等入口请求弹出快速查看（由 `TableDataTabView` 负责呈现）。
    public internal(set) var quickLookRequest: QuickLookContent?

    // MARK: 修订号（驱动 AppKit 桥接增量刷新）

    /// 数据 / 列 / 布局变化时自增；选中变化不自增。
    public private(set) var dataRevision = 0

    // MARK: 内部

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var fullLoadTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    /// 外键 `↗` 带入的过滤条件；未改动前不写回「按表记住的过滤」。
    @ObservationIgnored private var navigationFilter: FilterState?

    // MARK: 初始化

    public init(
        session: ConnectionSession,
        tab: Tab,
        metadataProvider: (any TableDataMetadataProviding)? = nil,
        preferences: Preferences,
        clock: Clock
    ) {
        self.session = session
        self.tab = tab
        self.database = tab.kind.database ?? session.selectedDatabase ?? ""
        self.table = tab.kind.objectName ?? ""
        self.metadataProvider = metadataProvider ?? LiveTableDataMetadataProvider(repository: session.meta)
        self.preferences = preferences
        self.clock = clock
        // 新标签的 RowLimitState 是默认值；此时用偏好里的「默认显示行数」。
        if tab.rowLimit.limit == RowLimit.default {
            self.rowLimit = preferences.rowLimit
        } else {
            self.rowLimit = tab.rowLimit.limit
        }
        self.sortOrders = tab.sort
        self.hiddenColumns = Set(tab.hiddenColumns)
        if let initialFilter = tab.initialFilter {
            // 外键 `↗` 跳转：强制使用带入的过滤条件，覆盖「按表记住的过滤」。
            self.filter = initialFilter
            self.filterDraft = initialFilter
            self.navigationFilter = initialFilter
        } else {
            let rememberedFilter = session.tableFilter(database: self.database, table: self.table) ?? tab.filter
            self.filter = rememberedFilter
            self.filterDraft = rememberedFilter ?? FilterState()
        }
        self.columnWidths = session.tableLayout(database: self.database, table: self.table)?.columnWidths ?? [:]
    }

    // MARK: 生命周期

    /// 首次进入标签时加载：元数据 → 数据。
    public func start() async {
        guard !didStart else { return }
        didStart = true
        await loadMetadata(force: false)
        guard isMetadataLoaded else { return }
        await performDataQuery()
    }

    /// 重新加载数据（`⌘R` / 刷新）；清空大字段缓存（`specs/03-data-browsing.md` §12）。
    public func refresh() async {
        // 有未提交改动时刷新不打断，只在状态栏提示暂存原样保留（`specs/04-data-editing.md` §12）。
        if hasPendingChanges {
            showToast("刷新会重新加载数据，你的修改会保留在暂存区")
        }
        fullRowCache.removeAll()
        await loadMetadata(force: true)
        guard isMetadataLoaded else { return }
        await performDataQuery()
    }

    /// 重新查询数据，不清元数据缓存。
    public func reloadCurrentPage() async {
        guard isMetadataLoaded else {
            await start()
            return
        }
        await performDataQuery()
    }

    /// 供视图 `onDisappear` 调用的取消入口：标签关闭时中断在途查询。
    public func cancelInFlight() {
        activeTask?.cancel()
        activeTask = nil
        stopElapsedTimer()
        fullLoadTask?.cancel()
        fullLoadTask = nil
        persistTask?.cancel()
        persistTask = nil
        Task { try? await session.cancelCurrentQuery() }
    }

    /// 等待当前挂起的加载（单测用）。
    public func waitForPendingWork() async {
        await activeTask?.value
        await fullLoadTask?.value
    }

    // MARK: 派生属性

    public var visibleColumns: [ColumnInfo] {
        columns.filter { !hiddenColumns.contains($0.name) }
    }

    public var rowLimitState: RowLimitState {
        RowLimitState(limit: rowLimit, rowCount: rowCountEstimate)
    }

    public var focusedRow: GridRow? {
        guard let focusedRowID else { return nil }
        return gridRows.first { $0.id == focusedRowID }
    }

    /// 数据行 + 新增行。网格、选中、复制、字段栏都看这个序列。
    public var gridRows: [GridRow] { rows + insertionRows }

    public var pendingCount: Int { pendingStore.totalCount }
    public var hasPendingChanges: Bool { !pendingStore.isEmpty }

    /// 放弃前是否需要确认：超过 5 条，或含新增 / 删除（`specs/04-data-editing.md` §11）。
    public var needsDiscardConfirmation: Bool {
        let counts = pendingStore.counts
        return counts.total > 5 || counts.insert > 0 || counts.delete > 0
    }

    /// 状态栏里不可编辑原因的文案（`specs/03-data-browsing.md` §11、`specs/04-data-editing.md` §2）。
    public var uneditableStatusText: String? {
        guard isMetadataLoaded, let reason = editability.reason else { return nil }
        switch reason {
        case .noPrimaryKey: return "该表没有主键，行顺序不保证，且不可编辑"
        case .view, .readOnlyConnection: return reason.message
        }
    }

    public var focusedColumnInfo: ColumnInfo? {
        guard let focusedColumn else { return nil }
        return columns.first { $0.name == focusedColumn }
    }

    /// 网格底部条的行数文案：`300 / 约 12,480 行 · content 1.2 MB`。
    ///
    /// 不管加载状态如何都给出一个可读的行数（首屏加载时显示 `0 / 约 12,480 行`）。
    /// 耗时不在里拼接：阈值判断统一在 `WorkspaceStatusText.tableDataSummary`
    /// （`specs/12-feedback.md` §6，只在 > 1 s 时显示）。
    public var rowCountBarText: String {
        var text = rowLimitState.statusText(visibleCount: rows.count)
        if let summary = largeFieldSizeSummary {
            text += " · \(summary)"
        }
        return text
    }

    /// 当前加载里被延迟加载的大字段实际大小摘要，例如 `content 1.2 MB`。
    ///
    /// 每个截断列取本次加载出现的最大字节数（`specs/03-data-browsing.md` §4）；
    /// 没有任何截断列时返回 nil，状态栏不追加内容。
    public var largeFieldSizeSummary: String? {
        var totals: [String: Int] = [:]
        for row in rows {
            for column in visibleColumns {
                guard let cell = row.cells[column.name],
                      cell.isTruncated,
                      let total = cell.totalByteCount else { continue }
                totals[column.name] = max(totals[column.name] ?? 0, total)
            }
        }
        guard !totals.isEmpty else { return nil }
        return totals
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \(ByteSize.format($0.value))" }
            .joined(separator: " · ")
    }

    public var editability: Editability {
        EditabilityEvaluator.evaluate(
            isView: isView,
            hasPrimaryKey: !primaryKeyColumns.isEmpty,
            isConnectionReadOnly: session.isReadOnly
        )
    }

    public var isEditable: Bool { editability.isEditable }

    /// 无主键表的状态栏提示（`specs/03-data-browsing.md` §11）。
    public var noPrimaryKeyHint: String? {
        primaryKeyColumns.isEmpty ? "该表没有主键，行顺序不保证，且不可编辑" : nil
    }

    public var isFilterVisible: Bool { filterDraft.isVisible }

    /// 是否有真正生效的过滤条件（用于区分「空表」与「被过滤掉」，`specs/12-feedback.md` §6）。
    public var hasActiveFilter: Bool { filter?.isActive == true }

    public var cellDisplayContext: CellDisplayContext {
        CellDisplayContext(
            nullText: preferences.nullDisplayText,
            tinyintAsCheckbox: preferences.tinyintAsCheckbox
        )
    }

    // MARK: 导出（`specs/08-import-export.md` §1）

    /// 当前过滤条件的**真实文本**（取自 `FilterSQLBuilder` 生成的 `WHERE` 子句），供导出面板说明用。
    public var filterSummary: String? { filterClause }

    /// 「导出…」的数据源：有过滤条件时导出过滤后的全部数据，否则整张表。
    public var exportSource: ExportSource {
        if let clause = filterClause, let summary = filterSummary {
            return .filteredTable(
                database: database,
                table: table,
                filterClause: clause,
                filterSummary: summary,
                rowCountEstimate: rowCountEstimate?.approximate
            )
        }
        return .table(database: database, table: table)
    }

    /// 「导出选中行…」的数据源：用选中行的主键定位键拼 `WHERE`。
    /// 无选中行、选中了未落库的新增行、或表没有主键时返回 nil。
    public func selectedRowsExportSource(rowIDs: [String]) -> ExportSource? {
        let selected = gridRows.filter { rowIDs.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        let escaper = session.mysql.makeEscaper()
        let introducer = session.mysql.charsetIntroducer
        var clauses: [String] = []
        for row in selected {
            guard let locator = row.locator, !locator.isEmpty,
                  let clause = try? PendingChangeSQL.locationClause(
                      locator,
                      introducer: introducer,
                      escaper: escaper
                  ) else {
                return nil
            }
            clauses.append("(\(clause))")
        }
        return .selectedRows(
            database: database,
            table: table,
            whereClause: clauses.joined(separator: " OR "),
            rowCount: selected.count
        )
    }

    // MARK: 排序

    /// 点列头：无 → 升序 → 降序 → 无；`⇧` 点击追加多列排序。
    public func toggleSort(column: String, additive: Bool) {
        // 有未提交改动时不打断，只在状态栏提示暂存原样保留（`specs/04-data-editing.md` §12、tech-design 09 §3）。
        if hasPendingChanges {
            showToast("改变排序会重新加载数据，你的修改会保留在暂存区")
        }
        if additive {
            var orders = sortOrders
            if let index = orders.firstIndex(where: { $0.column == column }) {
                if let next = orders[index].direction.next {
                    orders[index] = SortOrder(column: column, direction: next)
                } else {
                    orders.remove(at: index)
                }
            } else {
                orders.append(SortOrder(column: column, direction: .ascending))
            }
            sortOrders = orders
        } else {
            // 非追加：循环该列方向，并丢弃其它列。
            if let current = sortOrders.first(where: { $0.column == column }), let next = current.direction.next {
                sortOrders = [SortOrder(column: column, direction: next)]
            } else if sortOrders.contains(where: { $0.column == column }) {
                sortOrders = []
            } else {
                sortOrders = [SortOrder(column: column, direction: .ascending)]
            }
        }
        syncTab()
        bumpRevision()
        startQuery()
    }

    // MARK: 显示条数

    /// 切换最多显示多少行；从头重新加载并记住到偏好。
    public func setRowLimit(_ size: Int) {
        guard RowLimit.isValid(size), size != rowLimit else { return }
        rowLimit = size
        preferences.rowLimit = size
        syncTab()
        bumpRevision()
        startQuery()
    }

    /// 「精确统计」：只在用户点击时执行一次 `COUNT(*)`（L10）。
    public func runExactCount() {
        guard isMetadataLoaded, !isCountingExact else { return }
        isCountingExact = true
        bumpRevision()
        let sql = exactCountSQL()
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCountingExact = false }
            do {
                // 客户端自动查询不写入查询历史（`specs/06-query-editor.md` §5）。
                let result = try await self.session.execute(sql, database: self.database, recordHistory: false)
                if Task.isCancelled { return }
                if let text = result.firstResultSet?.rows.first?.cells.first?.text,
                   let count = Int64(text) {
                    self.rowCountEstimate = RowCountEstimate(approximate: count, isReliable: true, isExact: true)
                }
            } catch {
                if Task.isCancelled { return }
                self.copyNotice = "精确统计失败：\(Self.errorText(error))"
            }
            self.syncTab()
            self.bumpRevision()
        }
    }

    // MARK: 过滤（T10）

    /// 列名 → 列元数据。用于值控件类型与字面量生成。
    public func columnInfo(named name: String) -> ColumnInfo? {
        columns.first { $0.name == name }
    }

    /// 程序直接设置并应用过滤状态（T8 保留的接入口）。
    public func setFilter(_ state: FilterState?) {
        let newState = state ?? FilterState()
        filterDraft = newState
        filter = (newState.isActive || newState.isVisible) ? newState : nil
        filterError = nil
        filterErrorConditionIDs = []
        persistFilter()
        syncTab()
        bumpRevision()
        startQuery()
    }

    /// 打开 / 关闭过滤横条（`⌘F`）。
    public func toggleFilterVisible() {
        if filterDraft.isVisible {
            setFilterVisible(false)
        } else {
            setFilterVisible(true)
        }
    }

    public func setFilterVisible(_ visible: Bool) {
        filterDraft.isVisible = visible
        filter?.isVisible = visible
        if visible, filter == nil {
            filter = filterDraft
        }
        persistFilter()
        syncTab()
        bumpRevision()
    }

    /// 请求视图把焦点放到某条条件的值输入（`conditionID == nil` 时为 Raw 模式输入框）。
    public func requestFilterFocus(conditionID: UUID? = nil) {
        filterFocusConditionID = conditionID
        filterFocusToken &+= 1
    }

    // MARK: 行过滤器的应用与重置

    /// 点「应用」：校验 → 复制草稿到生效状态 → 重新加载。
    public func applyFilter() {
        let options = queryOptions
        let result: FilterBuildResult
        do {
            result = try FilterSQLBuilder.whereClause(
                for: filterDraft,
                columns: columns,
                escaping: options.escaping,
                introducer: options.introducer
            )
        } catch {
            presentFilterError(error)
            return
        }
        filterError = nil
        filterErrorConditionIDs = []
        if !result.skippedConditionIDs.isEmpty {
            showToast("已跳过 \(result.skippedConditionIDs.count) 条未填完整的条件")
        }
        if hasPendingChanges {
            showToast("切换过滤条件会重新加载数据，你的修改会保留在暂存区")
        }
        filter = filterDraft
        filterDraft.isVisible = true
        filter?.isVisible = true
        persistFilter()
        syncTab()
        bumpRevision()
        startQuery()
    }

    /// 点「重置」：清空全部条件并重新加载。
    public func resetFilter() {
        filterDraft.reset()
        filterDraft.isVisible = true
        filterError = nil
        filterErrorConditionIDs = []
        filter = filterDraft
        persistFilter()
        syncTab()
        bumpRevision()
        startQuery()
    }

    private func presentFilterError(_ error: Error) {
        guard let buildError = error as? FilterBuildError else {
            filterError = Self.errorText(error)
            filterErrorConditionIDs = []
            bumpRevision()
            return
        }
        filterError = buildError.message
        if case .unknownColumns(_, let ids) = buildError {
            filterErrorConditionIDs = Set(ids)
        } else {
            filterErrorConditionIDs = []
        }
        bumpRevision()
    }

    public func clearFilterError() {
        guard filterError != nil || !filterErrorConditionIDs.isEmpty else { return }
        filterError = nil
        filterErrorConditionIDs = []
        bumpRevision()
    }

    // MARK: 条件行编辑

    @discardableResult
    public func addFilterCondition(
        column: String? = nil,
        op: FilterOperator = .equal,
        value: String = ""
    ) -> UUID {
        let name = column ?? columns.first?.name ?? ""
        var condition = FilterCondition(column: name, op: op, value: value)
        applyColumnInfo(to: &condition)
        filterDraft.isRawMode = false
        filterDraft.conditions.append(condition)
        filterDraft.isVisible = true
        clearFilterError()
        persistFilter()
        syncTab()
        bumpRevision()
        return condition.id
    }

    public func removeFilterCondition(id: UUID) {
        filterDraft.conditions.removeAll { $0.id == id }
        filterErrorConditionIDs.remove(id)
        clearFilterError()
        persistFilter()
        syncTab()
        bumpRevision()
    }

    public func setFilterConditionEnabled(id: UUID, enabled: Bool) {
        updateCondition(id) { $0.isEnabled = enabled }
    }

    public func setFilterConditionColumn(id: UUID, column: String) {
        updateCondition(id) { condition in
            condition.column = column
            self.applyColumnInfo(to: &condition)
        }
    }

    public func setFilterConditionOperator(id: UUID, op: FilterOperator) {
        updateCondition(id) { $0.op = op }
    }

    public func setFilterConditionValue(id: UUID, value: String) {
        updateCondition(id) { $0.value = value }
    }

    public func setFilterConditionSecondValue(id: UUID, value: String) {
        updateCondition(id) { $0.secondValue = value }
    }

    public func setFilterCombination(_ combination: FilterCombination) {
        filterDraft.combination = combination
        clearFilterError()
        persistFilter()
        syncTab()
        bumpRevision()
    }

    /// 条件是否标记为「出错」（列不存在等）。
    public func isFilterConditionErrored(_ id: UUID) -> Bool {
        filterErrorConditionIDs.contains(id)
    }

    private func updateCondition(_ id: UUID, _ body: (inout FilterCondition) -> Void) {
        guard let index = filterDraft.conditions.firstIndex(where: { $0.id == id }) else { return }
        var condition = filterDraft.conditions[index]
        body(&condition)
        filterDraft.conditions[index] = condition
        filterErrorConditionIDs.remove(id)
        if filterError != nil { filterError = nil }
        persistFilter()
        syncTab()
        bumpRevision()
    }

    private func applyColumnInfo(to condition: inout FilterCondition) {
        guard let column = columns.first(where: { $0.name == condition.column }) else {
            condition.fieldType = nil
            condition.isBinary = false
            return
        }
        condition.fieldType = column.fieldType
        condition.isBinary = column.isBinary
    }

    // MARK: Raw SQL 模式

    public func switchFilterToRawMode() {
        filterDraft.switchToRawMode()
        filterDraft.isVisible = true
        clearFilterError()
        persistFilter()
        syncTab()
        bumpRevision()
        requestFilterFocus()
        showToast("高级条件不会被校验，请自行确认语法正确")
    }

    public func switchFilterToConditionsMode() {
        filterDraft.switchToConditionsMode()
        clearFilterError()
        persistFilter()
        syncTab()
        bumpRevision()
    }

    public func setRawWhere(_ text: String) {
        filterDraft.rawWhere = text
        clearFilterError()
        persistFilter()
        syncTab()
        bumpRevision()
    }

    // MARK: 快速筛选入口（右键 / 列头）

    public func applyQuickFilter(_ action: FilterState.QuickFilterAction) {
        switch action {
        case .byColumn(let column):
            filterDraft.isVisible = true
            let id = addFilterCondition(column: column, op: .equal, value: "")
            requestFilterFocus(conditionID: id)
        case .byValue(let column, let value):
            appendQuickCondition(column: column, op: .equal, value: value)
        case .excludeValue(let column, let value):
            appendQuickCondition(column: column, op: .notEqual, value: value)
        }
    }

    /// 右键单元格「按此值筛选 / 排除此值」：`NULL` 转成 `IS NULL` / `IS NOT NULL`。
    public func filterByCellValue(rowID: String, column: String, exclude: Bool) {
        guard let row = gridRows.first(where: { $0.id == rowID }),
              let value = row.cells[column]?.displayValue else { return }
        switch value {
        case .null:
            appendQuickCondition(column: column, op: exclude ? .isNotNull : .isNull, value: "")
        default:
            appendQuickCondition(column: column, op: exclude ? .notEqual : .equal, value: value.textValue ?? "")
        }
    }

    private func appendQuickCondition(column: String, op: FilterOperator, value: String) {
        filterDraft.switchToConditionsMode()
        var condition = FilterCondition(column: column, op: op, value: value)
        applyColumnInfo(to: &condition)
        filterDraft.conditions.append(condition)
        filterDraft.isVisible = true
        filterError = nil
        filterErrorConditionIDs = []
        filter = filterDraft
        persistFilter()
        syncTab()
        bumpRevision()
        startQuery()
    }

    // MARK: 外键跳转（`specs/03-data-browsing.md` §10）

    /// 外键 `↗`：在新标签打开被引用的表，并按「引用列 = 本行值」过滤到对应行。
    ///
    /// - 被引用表可能跨库，取外键元数据里的库名；
    /// - 字面量来自**原始值**（`ForeignKeyJumpResolver` 内部走 `SQLValueLiteral`），
    ///   不使用截断后的展示值；外键列被截断且拿不到完整值时提示并放弃（`07-data-grid.md` §3.1）；
    /// - 跳转是读操作，只读连接照常可用；
    /// - 过滤条件以 Raw 模式带入新标签（复用行定位字面量生成，不另造一套拼接）。
    public func openForeignKey(rowID: String, column: String) async {
        guard isMetadataLoaded,
              foreignKeyColumns.contains(column),
              let foreignKey = foreignKeys.first(where: { $0.columns.contains(column) }),
              let row = gridRows.first(where: { $0.id == rowID }),
              row.cells[column] != nil else { return }

        // 截断值不得参与跳转（复合外键要检查全部组件列）：先加载完整值；拿不到就明确提示并禁用。
        let needsLoad = foreignKey.columns.contains { foreignKeyColumn in
            row.cells[foreignKeyColumn]?.needsFullValueLoad == true
        }
        if needsLoad {
            await ensureFullValue(rowID: rowID, column: column)
            guard let updatedRow = gridRows.first(where: { $0.id == rowID }),
                  foreignKey.columns.allSatisfy({ updatedRow.cells[$0]?.hasCompleteValue == true }) else {
                showToast("外键列的值已截断且无法加载完整内容，暂不能跳转")
                return
            }
        }

        guard let currentRow = gridRows.first(where: { $0.id == rowID }) else { return }
        if currentRow.cells[column]?.displayValue.isNull == true {
            showToast("外键值为 NULL，无法跳转")
            return
        }

        let options = queryOptions
        guard let target = ForeignKeyJumpResolver.target(
            sourceDatabase: database,
            clickedColumn: column,
            columns: columns,
            values: currentRow.cells.mapValues(\.displayValue),
            foreignKeys: foreignKeys,
            escaping: options.escaping,
            introducer: options.introducer
        ) else {
            showToast("无法确定外键引用目标，暂不能跳转")
            return
        }

        let filter = FilterState(rawWhere: target.whereClause, isRawMode: true, isVisible: true)
        session.openTableData(
            database: target.database,
            table: target.table,
            forceNew: true,
            initialFilter: filter
        )
    }

    // MARK: 列显隐浮层

    /// `⌥⌘F`：打开 / 关闭列过滤器浮层（与 `⌘F` 行过滤器的 toggle 对称）。
    public func presentColumnFilter() {
        isColumnFilterPresented.toggle()
        bumpRevision()
    }

    public func dismissColumnFilter() {
        isColumnFilterPresented = false
        bumpRevision()
    }

    /// 应用列显隐（至少保留一列可见）。
    public func applyColumnVisibility(hidden: Set<String>) {
        guard hidden.count < columns.count else { return }
        hiddenColumns = hidden
        syncTab()
        persistLayout()
        bumpRevision()
    }

    // MARK: 列显隐与列宽

    public func setColumnHidden(_ name: String, hidden: Bool) {
        if hidden {
            // 至少保留一列可见。
            guard visibleColumns.count > 1 || !hidden else { return }
            hiddenColumns.insert(name)
        } else {
            hiddenColumns.remove(name)
        }
        syncTab()
        persistLayout()
        bumpRevision()
    }

    public func setColumnWidth(_ name: String, width: Double) {
        columnWidths[name] = width
        schedulePersistLayout()
    }

    public func persistLayoutNow() {
        persistTask?.cancel()
        persistTask = nil
        persistLayout()
    }

    // MARK: 选择

    /// 选区变化后立即回写（`07-data-grid.md` §5：不要等下一轮 runloop）。
    public func updateSelection(rowIDs: [String], focusedRowID: String?, focusedColumn: String?) {
        selectedRowIDs = Set(rowIDs)
        self.focusedRowID = focusedRowID ?? rowIDs.first
        self.focusedColumn = focusedColumn
        // 命中缓存时直接补全，避免重复二次加载。
        if let id = focusedRowID ?? rowIDs.first, let cached = fullRowCache[id] {
            applyFullValues(cached, toRowID: id)
        }
        manualFullLoadRequired = false
        fullRowError = nil
        scheduleInspectorAutoLoad()
        // 选中变化不触发网格 reloadData（只让字段栏重绘）。
    }

    public func clearSelection() {
        selectedRowIDs = []
        focusedRowID = nil
        focusedColumn = nil
    }

    /// 字段栏要展示的行（仅单选时有值）。
    public var inspectorRow: GridRow? {
        guard selectedRowIDs.count <= 1 else { return nil }
        if let focusedRowID, let row = gridRows.first(where: { $0.id == focusedRowID }) {
            return row
        }
        if let id = selectedRowIDs.first {
            return gridRows.first { $0.id == id }
        }
        return nil
    }

    // MARK: 大字段二次加载

    /// 字段栏选中单行后自动按需加载；合计超过 8 MB 时不自动取（L12）。
    private func scheduleInspectorAutoLoad() {
        guard inspectorRow != nil, preferences.showInspector else { return }
        requestFullRowLoad(force: false)
    }

    public func requestFullRowLoad(force: Bool) {
        fullLoadTask?.cancel()
        fullLoadTask = Task { [weak self] in
            await self?.performFullRowLoad(force: force, targetRowID: nil)
        }
    }

    /// 快速查看 / 编辑前确保某个单元格拿到完整值（显式用户动作，不受 8 MB 限制）。
    public func ensureFullValue(rowID: String, column: String) async {
        guard let row = gridRows.first(where: { $0.id == rowID }),
              let cell = row.cells[column],
              cell.needsFullValueLoad else { return }
        fullLoadTask?.cancel()
        fullLoadTask = nil
        await performFullRowLoad(force: true, targetRowID: rowID)
    }

    private func performFullRowLoad(force: Bool, targetRowID: String?) async {
        let row: GridRow?
        if let targetRowID {
            row = gridRows.first { $0.id == targetRowID }
        } else {
            guard selectedRowIDs.count <= 1 else { return }
            row = inspectorRow
        }
        guard let row else { return }
        let truncated = row.cells.filter { $0.value.needsFullValueLoad }
        guard !truncated.isEmpty else { return }

        guard let locator = row.locator, !locator.isEmpty else {
            fullRowError = "无法定位行以加载完整内容"
            manualFullLoadRequired = false
            bumpRevision()
            return
        }

        let totalBytes = truncated.compactMap { $0.value.totalByteCount }.reduce(0, +)
        if totalBytes > Self.autoLoadByteLimit && !force {
            manualFullLoadRequired = true
            fullRowError = nil
            bumpRevision()
            return
        }

        manualFullLoadRequired = false
        fullRowError = nil
        isLoadingFullRow = true
        bumpRevision()

        do {
            let query = try TableQueryBuilder.selectRowByKey(
                database: database,
                table: table,
                columns: columns,
                locator: locator,
                options: queryOptions
            )
            // 按主键取整行是客户端自动查询，不写入查询历史（`specs/06-query-editor.md` §5）。
            let result = try await session.execute(query.sql, database: database, recordHistory: false)
            if Task.isCancelled { return }
            guard let resultSet = result.firstResultSet, let firstRow = resultSet.rows.first else {
                isLoadingFullRow = false
                fullRowError = "该行已不存在，可能已被删除"
                bumpRevision()
                return
            }
            let values = MySQLValueMapping.values(for: firstRow, columns: resultSet.header.columns)
            var map: [String: SQLValue] = [:]
            for (index, resultColumn) in resultSet.header.columns.enumerated() where index < values.count {
                map[resultColumn.name] = values[index]
            }
            fullRowCache[row.id] = map
            applyFullValues(map, toRowID: row.id)
            isLoadingFullRow = false
            bumpRevision()
        } catch {
            if Task.isCancelled { return }
            isLoadingFullRow = false
            fullRowError = "加载完整内容失败：\(Self.errorText(error))"
            bumpRevision()
        }
    }

    private func applyFullValues(_ values: [String: SQLValue], toRowID rowID: String) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }) else { return }
        for (column, value) in values {
            guard var cell = rows[rowIndex].cells[column], cell.isTruncated else { continue }
            cell.fullValue = value
            rows[rowIndex].cells[column] = cell
        }
    }

    // MARK: 复制

    /// `⌘C`：有焦点单元格时复制单元格值，否则复制选中行（TSV）。
    public func makeDefaultCopy() -> CopyResult {
        if let _ = focusedColumn, selectedRowIDs.count <= 1, focusedRow != nil {
            return makeCopy(format: .cellValue)
        }
        return makeCopy(format: .rows)
    }

    /// 右键菜单「复制单元格值」：只复制指定的一个格子。
    public func makeCellCopy(rowID: String, column: String, format: CopyFormat) -> CopyResult {
        guard let row = gridRows.first(where: { $0.id == rowID }) else { return CopyResult(text: "") }
        let value = row.cells[column]?.displayValue ?? .null
        let text = CopyFormatter.format(
            rows: [[value]],
            columns: columns,
            format: format,
            database: database,
            table: table,
            options: copyOptions
        )
        return CopyResult(text: text)
    }

    public func makeCopy(format: CopyFormat) -> CopyResult {
        let columnNames = columns.map(\.name)
        let selectedRows: [GridRow] = {
            let selected = gridRows.filter { selectedRowIDs.contains($0.id) }
            if !selected.isEmpty { return selected }
            if let focusedRow { return [focusedRow] }
            return []
        }()

        func values(for row: GridRow, inColumn column: String) -> SQLValue {
            row.cells[column]?.displayValue ?? .null
        }

        func rowValues(_ row: GridRow) -> [SQLValue] {
            columnNames.map { values(for: row, inColumn: $0) }
        }

        let copiedRows: [[SQLValue]]
        switch format {
        case .cellValue:
            guard let row = selectedRows.first, let column = focusedColumn ?? columnNames.first else {
                return CopyResult(text: "")
            }
            copiedRows = [[values(for: row, inColumn: column)]]
        case .columnValues:
            guard let column = focusedColumn ?? columnNames.first else { return CopyResult(text: "") }
            copiedRows = selectedRows.map { [values(for: $0, inColumn: column)] }
        case .row:
            copiedRows = selectedRows.prefix(1).map(rowValues)
        default:
            copiedRows = selectedRows.map(rowValues)
        }

        let text = CopyFormatter.format(
            rows: copiedRows,
            columns: columns,
            format: format,
            database: database,
            table: table,
            options: copyOptions
        )
        var notice: String?
        if copiedRows.count > Self.copyNoticeRowThreshold {
            notice = "已复制 \(RowCountEstimate.grouped(Int64(copiedRows.count))) 行（\(ByteSize.format(text.utf8.count))）"
        }
        // L27 / `08-pending-changes.md` §9：SQL INSERT 复制时若含未加载完整的大字段，
        // 只能用截断值，给出明确警告（不静默地导出不完整数据）。
        if format == .sqlInsert {
            let truncatedCount = selectedRows.reduce(0) { partial, row in
                partial + row.cells.values.filter(\.needsFullValueLoad).count
            }
            if truncatedCount > 0 {
                let warning = "注意：\(truncatedCount) 个单元格的大字段尚未加载完整，INSERT 语句只包含截断值"
                notice = notice.map { "\($0) · \(warning)" } ?? warning
            }
        }
        if let notice {
            showCopyNotice(notice)
        }
        return CopyResult(text: text, notice: notice)
    }

    public func showCopyNotice(_ notice: String) {
        copyNotice = notice
        copyNoticeTask?.cancel()
        copyNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.copyNotice = nil
        }
    }

    /// 统一的轻提示入口（提交成功 / 复制 / 校验拦截都用它，`specs/12-feedback.md` §3）。
    public func showToast(_ text: String) {
        showCopyNotice(text)
    }

    // MARK: 快速查看

    /// 构建快速查看内容；`isLoading == true` 表示需要先二次加载。
    public func quickLookContent(rowID: String, column: String) -> QuickLookContent? {
        guard let columnInfo = columns.first(where: { $0.name == column }),
              let row = gridRows.first(where: { $0.id == rowID }),
              let cell = row.cells[column] else { return nil }
        let value = cell.displayValue
        let kind = CellDisplayFormatter.quickLookKind(for: columnInfo, value: value)
        let needsLoad = cell.needsFullValueLoad
        if needsLoad {
            return QuickLookContent(
                title: "快速查看 · \(column)",
                columnName: column,
                kind: kind,
                text: cell.value.isNull ? preferences.nullDisplayText : (cell.value.textValue ?? ""),
                isNull: value.isNull,
                isLoading: true,
                byteCount: cell.totalByteCount
            )
        }
        return quickLookContent(columnInfo: columnInfo, column: column, value: value, byteCount: cell.totalByteCount ?? value.byteCount)
    }

    private func quickLookContent(
        columnInfo: ColumnInfo,
        column: String,
        value: SQLValue,
        byteCount: Int?
    ) -> QuickLookContent {
        let kind = CellDisplayFormatter.quickLookKind(for: columnInfo, value: value)
        switch value {
        case .null:
            return QuickLookContent(
                title: "快速查看 · \(column)",
                columnName: column,
                kind: kind,
                text: preferences.nullDisplayText,
                isNull: true,
                byteCount: byteCount
            )
        case .binary(let data):
            return QuickLookContent(
                title: "快速查看 · \(column)",
                columnName: column,
                kind: kind,
                data: data,
                byteCount: byteCount ?? data.count
            )
        default:
            return QuickLookContent(
                title: "快速查看 · \(column)",
                columnName: column,
                kind: kind,
                text: value.textValue ?? "",
                byteCount: byteCount
            )
        }
    }

    // MARK: 查询生成

    private var queryOptions: TableQueryOptions {
        TableQueryOptions(
            lazyLargeColumns: preferences.lazyLargeColumns,
            largeColumnPrefixLength: preferences.lazyLargeColumnThreshold,
            escaping: session.serverInfo?.hasNoBackslashEscapes == true ? .noBackslashEscapes : .mysqlDefault,
            introducer: session.mysql.charsetIntroducer
        )
    }

    private var filterClause: String? {
        guard let filter, filter.isActive else { return nil }
        let options = queryOptions
        return try? FilterSQLBuilder.whereClause(
            for: filter,
            columns: columns,
            escaping: options.escaping,
            introducer: options.introducer
        ).clause
    }

    private func exactCountSQL() -> String {
        var sql = "SELECT COUNT(*) AS `__mtl_count` FROM \(SQLIdentifier.qualified(database: database, table: table))"
        if let clause = filterClause {
            sql += " WHERE \(clause)"
        }
        return sql
    }

    private func startQuery() {
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.performDataQuery()
        }
    }

    // MARK: 元数据加载

    private func loadMetadata(force: Bool) async {
        do {
            let metadata = try await metadataProvider.loadMetadata(database: database, table: table, forceRefresh: force)
            columns = metadata.columns
            tableInfo = metadata.tableInfo
            isView = metadata.isView
            primaryKeyColumns = metadata.primaryKeyColumns
            foreignKeyColumns = metadata.foreignKeyColumns
            foreignKeys = metadata.foreignKeys
            createStatement = metadata.createStatement
            isMetadataLoaded = true
            if let layout = session.tableLayout(database: database, table: table) {
                columnWidths = layout.columnWidths
                if !layout.hiddenColumns.isEmpty {
                    hiddenColumns = Set(layout.hiddenColumns)
                }
            }
            rowCountEstimate = try? await metadataProvider.loadRowCountEstimate(
                database: database,
                table: table,
                forceRefresh: force
            )
            loadState = .idle
            bumpRevision()
        } catch {
            isMetadataLoaded = false
            rows = []
            loadState = .failed("加载表结构失败：\(Self.errorText(error))")
            bumpRevision()
        }
    }

    // MARK: 数据查询

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedMilliseconds = 0
        let start = clock.now
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.elapsedMilliseconds = max(0, Int(self.clock.now.timeIntervalSince(start) * 1000))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func performDataQuery() async {
        guard isMetadataLoaded else { return }
        loadState = .loading

        let started = clock.now
        startElapsedTimer()
        defer {
            // 加载结束：停表并把本次耗时同时固化到 `lastQueryMilliseconds`。
            stopElapsedTimer()
            let total = max(0, Int(clock.now.timeIntervalSince(started) * 1000))
            elapsedMilliseconds = total
            lastQueryMilliseconds = total
            // 取消（`cancelInFlight` / ⌘. / 状态栏「取消」）时上面几条路径会提前 return，
            // 不重置就会卡在加载遮罩；这里收口到终止态，保留已取到的旧数据。
            if loadState == .loading {
                loadState = rows.isEmpty ? .idle : .loaded
            }
        }

        let options = queryOptions
        let query = TableQueryBuilder.selectRows(
            database: database,
            table: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            sort: sortOrders,
            filterClause: filterClause,
            rowLimit: rowLimit,
            options: options
        )

        do {
            // 表数据查询是客户端自动查询，不写入查询历史（`specs/06-query-editor.md` §5）。
            let result = try await session.execute(query.sql, database: database, recordHistory: false)
            if Task.isCancelled { return }

            guard let resultSet = result.firstResultSet else {
                rows = []
                rebuildPendingPresentation()
                syncPendingFlag()
                loadState = .loaded
                syncTab()
                bumpRevision()
                return
            }

            rows = makeRows(from: resultSet, query: query, options: options)
            if let focused = focusedRowID, !gridRows.contains(where: { $0.id == focused }) {
                // 刷新后焦点行已不在本次加载里：保留仍存在的选中项，清掉焦点行。
                focusedRowID = nil
            }
            if !selectedRowIDs.isEmpty {
                let present = Set(gridRows.map(\.id))
                selectedRowIDs = selectedRowIDs.intersection(present)
            }
            if let cached = focusedRowID, let map = fullRowCache[cached] {
                applyFullValues(map, toRowID: cached)
            }
            // 重新加载后把暂存投影回新拉到的行（暂存不因刷新丢失，`specs/03-data-browsing.md` §12）。
            rebuildPendingPresentation()
            syncPendingFlag()
            loadState = .loaded
            syncTab()
            bumpRevision()
        } catch {
            if Task.isCancelled { return }
            rows = []
            loadState = .failed(Self.errorText(error))
            bumpRevision()
        }
    }

    private func makeRows(
        from resultSet: MySQLBufferedResultSet,
        query: TableQuery,
        options: TableQueryOptions
    ) -> [GridRow] {
        let resultColumns = resultSet.header.columns
        var indexByName: [String: Int] = [:]
        for (index, column) in resultColumns.enumerated() where indexByName[column.name] == nil {
            indexByName[column.name] = index
        }
        var projectionByName: [String: ColumnProjection] = [:]
        for projection in query.projections { projectionByName[projection.name] = projection }

        let prefixLength = max(1, options.largeColumnPrefixLength)
        let columnByName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        return resultSet.rows.enumerated().map { rowOffset, rawRow in
            let values = MySQLValueMapping.values(for: rawRow, columns: resultColumns)
            var cells: [String: GridCell] = [:]
            for column in columns {
                guard let index = indexByName[column.name], index < values.count else { continue }
                let value = values[index]
                var cell = GridCell(value: value)
                if let projection = projectionByName[column.name], projection.isTruncated {
                    var total: Int?
                    if let alias = projection.lengthAlias,
                       let lengthIndex = indexByName[alias],
                       lengthIndex < values.count {
                        total = Self.intValue(values[lengthIndex])
                    }
                    cell.totalByteCount = total
                    cell.isTruncated = Self.isTruncated(value, totalBytes: total, prefixLength: prefixLength)
                }
                cells[column.name] = cell
            }
            let locator = makeLocator(cells: cells, columnByName: columnByName)
            let identity = locator?.identityString ?? "row:\(rowOffset)"
            return GridRow(id: identity, rowIndexInPage: rowOffset, locator: locator, cells: cells)
        }
    }

    private func makeLocator(cells: [String: GridCell], columnByName: [String: ColumnInfo]) -> RowLocator? {
        guard !primaryKeyColumns.isEmpty else { return nil }
        var keys: [RowKeyValue] = []
        for name in primaryKeyColumns {
            guard let cell = cells[name], let column = columnByName[name] else { return nil }
            keys.append(RowKeyValue(
                column: name,
                value: cell.value,
                fieldType: column.fieldType,
                isBinary: column.isBinary
            ))
        }
        return keys.isEmpty ? nil : RowLocator(keys: keys)
    }

    // MARK: Tab 同步与持久化

    private func syncTab() {
        tab.rowLimit = RowLimitState(limit: rowLimit, rowCount: rowCountEstimate)
        tab.sort = sortOrders
        tab.filter = filterDraft
        tab.hiddenColumns = columns.map(\.name).filter { hiddenColumns.contains($0) }
        tab.focusedColumn = focusedColumn
    }

    /// 把过滤器草稿写回 WorkspaceStateStore（偏好关闭时自然被 `saveTableFilter` 忽略）。
    private func persistFilter() {
        // 外键 `↗` 带入的条件不是用户对该表的记忆，未改动前不写回，避免污染「按表记住的过滤」。
        if let navigationFilter, navigationFilter == filterDraft { return }
        let hasContent = filterDraft.isActive || filterDraft.isVisible
        session.saveTableFilter(database: database, table: table, filter: hasContent ? filterDraft : nil)
    }

    private func schedulePersistLayout() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persistLayout()
        }
    }

    private func persistLayout() {
        session.saveTableLayout(
            database: database,
            table: table,
            layout: TableLayout(
                columnWidths: columnWidths,
                hiddenColumns: columns.map(\.name).filter { hiddenColumns.contains($0) }
            )
        )
    }

    private var copyOptions: CopyOptions {
        CopyOptions(
            csvDelimiter: preferences.csvDelimiter.byte,
            lineEnding: preferences.csvLineEnding,
            nullRepresentation: preferences.csvNullRepresentation
        )
    }

    internal func bumpRevision() {
        dataRevision &+= 1
    }

    // MARK: 工具

    static func isTruncated(_ value: SQLValue, totalBytes: Int?, prefixLength: Int) -> Bool {
        guard let totalBytes else { return false }
        guard totalBytes > prefixLength else { return false }
        switch value {
        case .text(let text): return text.count >= prefixLength
        case .binary(let data): return data.count >= prefixLength
        default: return false
        }
    }

    static func intValue(_ value: SQLValue) -> Int? {
        switch value {
        case .integer(let number): return Int(number)
        case .text(let text): return Int(text)
        case .decimal(let text): return Int(text)
        case .bool(let flag): return flag ? 1 : 0
        default: return nil
        }
    }

    static func errorText(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "错误 \(mysqlError.code)：\(mysqlError.message)"
        }
        return String(describing: error)
    }
}

extension SQLValue {
    /// 文本表示；用于快速查看与复制前的兜底。
    var textValue: String? {
        switch self {
        case .null: return nil
        case .text(let text): return text
        case .integer(let number): return String(number)
        case .decimal(let text): return text
        case .bool(let flag): return flag ? "1" : "0"
        case .binary(let data): return data.hexString
        }
    }

    var byteCount: Int? {
        switch self {
        case .binary(let data): return data.count
        case .text(let text): return text.utf8.count
        default: return nil
        }
    }
}
