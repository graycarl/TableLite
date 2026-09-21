import Combine
import Foundation
import os

// MARK: - 表数据 ViewModel
//
// 一个表数据标签的唯一可变状态持有者。视图只读状态、只发意图。
// 设计依据：
// - docs/tech-designs/06-ui-layer.md §2 §4 §6（状态归属、增量刷新、线程与更新）；
// - docs/tech-designs/07-data-grid.md（分页 / 排序 / 大字段两阶段加载）；
// - docs/tech-designs/08-pending-changes.md（暂存区、行定位、提交）；
// - docs/tech-designs/14-row-inspector.md（字段栏是焦点单元格的投影）；
// - specs/03-data-browsing.md、specs/04-data-editing.md、specs/05-filtering.md。
//
// 线程：整个类型 `@MainActor`。数据库访问全部 `await` 到 `MySQLSession`（actor）/
// `MetaRepository`（actor）/ `TableDataLoader`，回主线程后再写 `@Published`。
//
// 硬约束：
// - 编辑一律进 `pending`，绝不直接改 `page`；
// - 截断的大字段在未加载完整值前不允许写回（docs/tech-designs/08-pending-changes.md §9）；
// - 错误不吞：至少经 `os.Logger`（subsystem `com.graycarl.tablelite`，category `mysql`）。

/// 表数据 ViewModel 自身的错误（区别于底层 `MySQLError` / `PendingChangeError`）。
enum TableDataViewModelError: Error, Hashable, Sendable {
    /// 结构尚未加载完成。
    case structureNotLoaded
    /// 大字段仍是截断值，必须先加载完整值再编辑。
    case truncatedValueNotLoaded(column: String)

    var message: String {
        switch self {
        case .structureNotLoaded:
            return "表结构尚未加载完成"
        case .truncatedValueNotLoaded(let column):
            return "「\(column)」是截断的大字段，请先加载完整内容后再编辑"
        }
    }
}

/// 提交进度（供工具栏 / 状态栏显示「正在提交 3/7…」）。
struct CommitProgress: Hashable, Sendable {
    var completed: Int
    var total: Int
}

@MainActor
final class TableDataViewModel: ObservableObject {

    // MARK: - 依赖（不可变）

    let ref: TableRef

    private let connectionID: UUID
    private let session: MySQLSession
    private let meta: MetaRepository
    private let loader: TableDataLoader
    private let preferences: PreferencesStore
    private let tableState: TableStateStore
    private let isReadOnlyConnection: Bool
    /// 暂存区状态变化回调。参数按契约传 `pending.isEmpty`：
    /// `true` 表示当前没有未提交改动，`false` 表示有。
    private let onPendingChangeStateChanged: @MainActor (Bool) -> Void

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "mysql")

    // MARK: - 数据状态

    @Published private(set) var structure: TableStructure?
    @Published private(set) var page: TableDataPage?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: MySQLError?
    @Published private(set) var editability: EditabilityReason

    // MARK: - 分页 / 排序 / 过滤

    @Published var pageIndex: Int = 0
    @Published var pageSize: Int
    @Published var sort: [SortDescriptor]
    @Published var filter: FilterSet
    @Published private(set) var rowEstimate: UInt64?
    @Published private(set) var isCountingExactly = false
    /// 精确统计完成后为 true，状态栏显示「N 行」而不是「约 N 行」。
    @Published private(set) var isExactCount = false

    // MARK: - 列呈现

    @Published var hiddenColumns: Set<String>
    @Published var columnWidths: [String: Double]

    // MARK: - 选择 / 焦点（唯一真源，字段栏是它的投影）

    @Published var focusedRow: RowIdentity?
    @Published var focusedColumn: String?
    @Published var selectedRows: Set<RowIdentity> = []

    // MARK: - 暂存

    /// 变更暂存区。结构加载完成后、以及每次 `load()` 时用真实结构重建。
    ///
    /// 用 `private(set) var`（而非 `let`）是因为 `PendingChangeStore` 需要一个
    /// `TableStructure`，而结构是 `load()` 时才异步拿到的。
    private(set) var pending: PendingChangeStore

    // MARK: - 大字段二次加载

    @Published private(set) var fullValues: [RowIdentity: [String: CellValue]] = [:]
    @Published private(set) var loadingFullValues: Set<RowIdentity> = []
    /// 二次加载失败 / 行不存在的提示（对应 specs/03 §4「无法定位行…」「该行已不存在…」）。
    @Published private(set) var fullValueError: String?

    // MARK: - 提交状态

    @Published private(set) var isCommitting = false
    @Published private(set) var commitProgress: CommitProgress?

    // MARK: - 私有

    /// 列名 → 在 `structure.columns` / `row.values` 里的下标。
    private var columnIndexByName: [String: Int] = [:]
    /// 并发加载的代际号，丢弃过期的分页结果。
    private var loadGeneration = 0

    // MARK: - 初始化

    init(connectionID: UUID,
         ref: TableRef,
         session: MySQLSession,
         meta: MetaRepository,
         loader: TableDataLoader,
         preferences: PreferencesStore,
         tableState: TableStateStore,
         isReadOnly: Bool,
         onPendingChangeStateChanged: @escaping @MainActor (Bool) -> Void) {
        self.connectionID = connectionID
        self.ref = ref
        self.session = session
        self.meta = meta
        self.loader = loader
        self.preferences = preferences
        self.tableState = tableState
        self.isReadOnlyConnection = isReadOnly
        self.onPendingChangeStateChanged = onPendingChangeStateChanged

        // 始终读一次磁盘状态：列显隐 / 过滤由不同偏好开关分别控制。
        let saved = tableState.state(connectionID: connectionID, table: ref)
        self.pageSize = preferences.rememberTableState ? (saved.pageSize ?? preferences.pageSize) : preferences.pageSize
        self.sort = preferences.rememberTableState ? saved.sort : []
        self.hiddenColumns = preferences.rememberTableState ? saved.hiddenColumns : []
        self.columnWidths = preferences.rememberTableState ? saved.columnWidths : [:]
        self.filter = preferences.rememberTableFilters ? saved.filter : FilterSet()
        self.editability = isReadOnly ? .readOnlyConnection : .editable
        self.pending = PendingChangeStore(table: ref, structure: Self.placeholderStructure(for: ref))
    }

    // MARK: - 派生状态

    var visibleColumns: [TableColumn] {
        allColumns.filter { !$0.isInvisible && !hiddenColumns.contains($0.name) }
    }

    /// 字段栏用：不受列显隐影响，列顺序按表定义。
    var allColumns: [TableColumn] { structure?.columns ?? [] }

    var focusedRowData: TableDataRow? {
        guard let focusedRow else { return nil }
        if let pageRow = pageRow(for: focusedRow) { return merged(pageRow) }
        if let structure, let change = pending.change(for: focusedRow), change.kind == .insert {
            return insertedRow(identity: focusedRow, change: change, structure: structure)
        }
        return nil
    }

    /// 选中行数：有显式选区时取选区大小，否则单个焦点算 1。
    var selectionCount: Int {
        if !selectedRows.isEmpty { return selectedRows.count }
        return focusedRow == nil ? 0 : 1
    }

    var isDirty: Bool { !pending.isEmpty }

    var pendingStats: PendingChangeStats { pending.stats }

    // MARK: - 分页派生

    var hasNextPage: Bool { page?.hasNextPage ?? false }
    var hasPreviousPage: Bool { pageIndex > 0 }

    /// 当前页 = 已加载行（含暂存的新增行），供网格数据源使用。
    var displayRows: [TableDataRow] {
        var rows = (page?.rows ?? []).map(merged)
        if let structure {
            for change in pending.changes where change.kind == .insert {
                rows.append(insertedRow(identity: change.identity, change: change, structure: structure))
            }
        }
        return rows
    }

    /// 是否能靠主键定位行（无主键 → 大字段无法二次加载）。
    var canLocateRows: Bool { !(structure?.primaryKeyColumns.isEmpty ?? true) }

    // MARK: - 状态栏文案

    /// `行 1–300`
    var rowRangeText: String {
        TableDataViewModelLogic.rowRangeText(
            pageIndex: pageIndex,
            pageSize: pageSize,
            rowCount: page?.rows.count ?? 0
        )
    }

    /// `约 12,480 行` / 精确统计后 `12,480 行` / 未知时 `行数未知`。
    var rowCountText: String {
        TableDataViewModelLogic.rowCountText(estimate: rowEstimate, isExact: isExactCount)
    }

    /// `第 1 页`
    var pageNumberText: String { "第 \(pageIndex + 1) 页" }

    /// `300 行/页`
    var pageSizeText: String { "\(pageSize) 行/页" }

    /// 无主键提示（specs/03 §11）。
    var noPrimaryKeyWarning: String? {
        guard let structure, structure.kind == .table, structure.primaryKeyColumns.isEmpty else { return nil }
        return "该表没有主键，分页顺序不保证，且不可编辑"
    }

    /// 深翻页提示（L11）。
    var deepOffsetWarning: String? {
        guard TableDataViewModelLogic.isDeepOffset(pageIndex: pageIndex, pageSize: pageSize) else { return nil }
        return "偏移量很大，翻页会越来越慢；建议用过滤器缩小范围后再翻页"
    }

    // MARK: - 加载

    /// 首次加载：结构 + 第一页。
    func load() async {
        if structure == nil {
            await loadStructure()
        }
        guard structure != nil else { return }
        await loadPage()
    }

    /// 保持页码 / 排序 / 过滤重新查询当前页。
    func reload() async {
        guard structure != nil else {
            await load()
            return
        }
        await loadPage()
    }

    /// `⌘R`：清空大字段缓存后重新查询当前页（暂存原样保留）。
    func refresh() async {
        fullValues.removeAll()
        loadingFullValues.removeAll()
        fullValueError = nil
        await reload()
    }

    private func loadStructure() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let loaded = try await meta.structure(ref)
            structure = loaded
            columnIndexByName = Dictionary(
                uniqueKeysWithValues: loaded.columns.enumerated().map { ($0.element.name, $0.offset) }
            )
            // 结构到手后才能构造真正可用的暂存区。
            pending = PendingChangeStore(table: ref, structure: loaded)
            updateEditability()
            pendingDidChange()
        } catch {
            let mapped = mapError(error)
            logger.error("读取表结构失败：\(String(describing: error), privacy: .public)")
            loadError = mapped
        }
    }

    private func loadPage() async {
        guard let structure else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let request = TablePageRequest(
                schema: ref.database,
                table: ref.table,
                pageIndex: pageIndex,
                pageSize: pageSize,
                sort: sort,
                filter: filter
            )
            let loaded = try await loader.loadPage(
                ref: ref,
                structure: structure,
                request: request,
                lazyLarge: preferences.lazyLargeColumns,
                largeThreshold: preferences.largeValueThreshold
            )
            guard generation == loadGeneration else { return }
            page = loaded
            rowEstimate = loaded.rowEstimate
            isExactCount = false
            pruneSelection()
        } catch {
            guard generation == loadGeneration else { return }
            logger.error("加载表数据失败：\(String(describing: error), privacy: .public)")
            loadError = mapError(error)
        }
    }

    // MARK: - 分页 / 排序 / 过滤

    func goToPage(_ index: Int) async {
        let target = max(0, index)
        guard target != pageIndex else { return }
        pageIndex = target
        await loadPage()
    }

    func setPageSize(_ size: Int) async {
        let clamped = min(max(size, 1), TableDataViewModelLogic.maxPageSize)
        guard clamped != pageSize else { return }
        pageSize = clamped
        pageIndex = 0
        savePresentationState()
        await loadPage()
    }

    /// 点列头：无 → 升 → 降 → 无；`append`（⇧ 点击）追加 / 切换多列排序。
    func toggleSort(column: String, append: Bool) async {
        guard allColumns.contains(where: { $0.name == column }) else { return }
        if append {
            if let index = sort.firstIndex(where: { $0.column == column }) {
                if sort[index].descending {
                    sort.remove(at: index)
                } else {
                    sort[index].descending = true
                }
            } else {
                sort.append(SortDescriptor(column: column, descending: false))
            }
        } else if sort.count == 1, sort[0].column == column {
            if sort[0].descending {
                sort = []
            } else {
                sort[0].descending = true
            }
        } else {
            sort = [SortDescriptor(column: column, descending: false)]
        }
        pageIndex = 0
        savePresentationState()
        await loadPage()
    }

    func setSort(_ sort: [SortDescriptor]) async {
        self.sort = sort
        pageIndex = 0
        savePresentationState()
        await loadPage()
    }

    /// 应用过滤器：回到第一页重新查询；暂存不受影响（specs/05 §3）。
    func applyFilter(_ filter: FilterSet) async {
        self.filter = filter
        pageIndex = 0
        savePresentationState()
        await loadPage()
    }

    /// 精确统计（绝不自动执行，specs/03 §2）。
    func countExactly() async {
        guard !isCountingExactly, let structure else { return }
        isCountingExactly = true
        defer { isCountingExactly = false }
        do {
            let literalizer = await session.literalizer()
            let filterResult = FilterSQLBuilder.build(filter, columns: structure.columns, using: literalizer)
            if let issue = filterResult.issues.first {
                loadError = .unsupported(issue.message)
                return
            }
            let count = try await loader.preciseCount(ref: ref, whereClause: filterResult.sql)
            rowEstimate = count
            isExactCount = true
        } catch {
            logger.error("精确统计失败：\(String(describing: error), privacy: .public)")
            loadError = mapError(error)
        }
    }

    // MARK: - 列状态持久化

    func setColumnWidth(_ width: Double, column: String) {
        columnWidths[column] = width
        savePresentationState()
    }

    func setHiddenColumns(_ hidden: Set<String>) {
        // 至少保留一列可见（specs/05 §2）。
        let allVisible = Set(allColumns.filter { !$0.isInvisible }.map(\.name))
        guard !allVisible.isSubset(of: hidden) || allVisible.isEmpty else {
            logger.notice("列显隐不能隐藏全部列，已忽略")
            return
        }
        hiddenColumns = hidden
        savePresentationState()
    }

    // MARK: - 大字段二次加载

    /// 选中单行后调用：合计 ≤ 8MB 自动加载完整值，超过只暴露「加载完整内容…」。
    func loadFullValuesIfNeeded() async {
        guard preferences.lazyLargeColumns,
              let structure,
              let focusedRow,
              !focusedRow.isInserted,
              !structure.primaryKeyColumns.isEmpty,
              let pageRow = pageRow(for: focusedRow) else { return }

        let truncatedColumns = structure.columns.filter { column in
            column.isLargeObject
                && pageRow.truncatedLengths[column.name] != nil
                && fullValues[focusedRow]?[column.name] == nil
        }
        guard !truncatedColumns.isEmpty else { return }

        let totalBytes = truncatedColumns.reduce(0) { partial, column in
            partial + (pageRow.truncatedLengths[column.name] ?? 0)
        }
        guard TableDataViewModelLogic.shouldAutoLoadFullValues(totalBytes: totalBytes) else { return }
        await fetchFullValues(row: focusedRow, columns: truncatedColumns)
    }

    func loadFullValue(row: RowIdentity, column: String) async {
        guard let structure,
              let column = structure.columns.first(where: { $0.name == column }) else { return }
        await fetchFullValues(row: row, columns: [column])
    }

    /// 该行是否还有未加载的截断大字段（UI 据此显示「加载完整内容…」）。
    func canLoadFullValue(row: RowIdentity) -> Bool {
        guard preferences.lazyLargeColumns,
              let structure,
              !row.isInserted,
              !structure.primaryKeyColumns.isEmpty,
              let pageRow = pageRow(for: row) else { return false }
        let loaded = fullValues[row] ?? [:]
        return structure.columns.contains { column in
            column.isLargeObject
                && pageRow.truncatedLengths[column.name] != nil
                && loaded[column.name] == nil
        }
    }

    func fullValue(row: RowIdentity, column: String) -> CellValue? {
        fullValues[row]?[column]
    }

    private func fetchFullValues(row: RowIdentity, columns: [TableColumn]) async {
        guard let structure, !row.isInserted, !columns.isEmpty else { return }
        guard !structure.primaryKeyColumns.isEmpty else {
            fullValueError = "无法定位行以加载完整内容"
            return
        }
        guard !loadingFullValues.contains(row) else { return }
        let locator = locator(for: row, structure: structure)
        guard !locator.isEmpty else {
            fullValueError = "无法定位行以加载完整内容"
            return
        }
        loadingFullValues.insert(row)
        defer { loadingFullValues.remove(row) }
        do {
            let values = try await loader.loadFullValues(
                ref: ref,
                structure: structure,
                locator: locator,
                columns: columns
            )
            var cached = fullValues[row] ?? [:]
            for (name, value) in values { cached[name] = value }
            fullValues[row] = cached
            fullValueError = nil
        } catch let error as TableDataLoaderError {
            logger.error("加载大字段失败：\(error.message, privacy: .public)")
            fullValueError = error.message
        } catch {
            logger.error("加载大字段失败：\(String(describing: error), privacy: .public)")
            fullValueError = mapError(error).title
        }
    }

    // MARK: - 编辑（字段栏调用）

    /// 把一次字段编辑写进暂存区（不直接改 `page`）。
    func applyEdit(row: RowIdentity, column: String, value: CellValue) throws {
        guard let structure else { throw TableDataViewModelError.structureNotLoaded }

        if row.isInserted {
            pending.setInsertValue(row: row, column: column, value: value)
            pendingDidChange()
            return
        }

        // 安全保证：截断的大字段未加载完整值前不允许写回（docs/08 §9）。
        if isTruncated(row: row, column: column), fullValue(row: row, column: column) == nil {
            throw TableDataViewModelError.truncatedValueNotLoaded(column: column)
        }

        let original = originalValue(row: row, column: column) ?? .null
        try pending.applyEdit(
            row: row,
            locator: locator(for: row, structure: structure),
            column: column,
            originalValue: original,
            newValue: value
        )
        pendingDidChange()
    }

    @discardableResult
    func insertRow() -> RowIdentity {
        guard editability.isEditable else {
            logger.notice("不可编辑的表尝试插入行，已忽略")
            return RowIdentity.inserted()
        }
        let identity = pending.beginInsert()
        focusedRow = identity
        selectedRows = [identity]
        focusedColumn = allColumns.first(where: { !$0.isGenerated })?.name
        pendingDidChange()
        return identity
    }

    func setInsertValue(row: RowIdentity, column: String, value: CellValue) {
        pending.setInsertValue(row: row, column: column, value: value)
        pendingDidChange()
    }

    func cancelInsert(row: RowIdentity) {
        pending.cancelInsert(row: row)
        if focusedRow == row {
            focusedRow = nil
            focusedColumn = nil
        }
        selectedRows.remove(row)
        pendingDidChange()
    }

    func deleteRows(_ rows: Set<RowIdentity>) {
        guard let structure, editability.isEditable else { return }
        for row in ordered(rows) {
            if row.isInserted {
                pending.cancelInsert(row: row)
                continue
            }
            pending.applyDelete(row: row, locator: locator(for: row, structure: structure))
        }
        pendingDidChange()
    }

    /// 复制行：清空自增列，其余列按当前显示值预填，作为新增行进入暂存。
    func duplicateRows(_ rows: Set<RowIdentity>) {
        guard let structure, editability.isEditable else { return }
        var inserted: [RowIdentity] = []
        for row in ordered(rows) where !row.isInserted {
            var source: [String: CellValue] = [:]
            for column in structure.columns {
                // 截断且未加载完整值的大字段绝不复制，避免把截断前缀写进新增行
                //（docs/tech-designs/08-pending-changes.md §9 的安全保证）。
                if isTruncated(row: row, column: column.name),
                   fullValue(row: row, column: column.name) == nil {
                    continue
                }
                if let value = currentValue(row: row, column: column.name) {
                    source[column.name] = value
                }
            }
            let copied = TableDataViewModelLogic.duplicateColumnValues(
                columns: structure.columns,
                values: source
            )
            let identity = pending.beginInsert()
            for (column, value) in copied {
                pending.setInsertValue(row: identity, column: column, value: value)
            }
            inserted.append(identity)
        }
        guard let first = inserted.first else { return }
        focusedRow = first
        selectedRows = Set(inserted)
        focusedColumn = allColumns.first(where: { !$0.isGenerated })?.name
        pendingDidChange()
    }

    func undoRow(_ row: RowIdentity) {
        pending.undo(row: row)
        if row.isInserted, focusedRow == row {
            focusedRow = nil
            focusedColumn = nil
        }
        selectedRows.remove(row)
        pendingDidChange()
    }

    func discardAll() async {
        pending.discardAll()
        pendingDidChange()
        await loadPage()
    }

    func previewStatements() async -> [PendingSQLStatement] {
        let literalizer = await session.literalizer()
        return pending.sqlStatements(using: literalizer)
    }

    /// 提交：只在只读连接上拒绝；成功后清空暂存并重新查询当前页。
    func commit() async throws -> CommitOutcome {
        guard editability == .editable else {
            throw MySQLError.unsupported(editability.message ?? "当前表不可编辑")
        }
        guard !pending.isEmpty else {
            return CommitOutcome(executedCount: 0, elapsed: .zero)
        }

        isCommitting = true
        let literalizer = await session.literalizer()
        let statements = pending.sqlStatements(using: literalizer)
        commitProgress = CommitProgress(completed: 0, total: statements.count)

        let outcome: CommitOutcome
        do {
            outcome = try await PendingChangeCommitter(session: session).commit(
                statements,
                clock: LiveClock()
            ) { [weak self] completed, total in
                Task { @MainActor in
                    self?.commitProgress = CommitProgress(completed: completed, total: total)
                }
            }
        } catch {
            isCommitting = false
            commitProgress = nil
            logger.error("提交失败：\(String(describing: error), privacy: .public)")
            throw error
        }

        pending.discardAll()
        pendingDidChange()
        isCommitting = false
        commitProgress = nil
        await loadPage()
        return outcome
    }

    /// 该行该列在数据库里的原值：优先冻结基准值，其次完整值缓存，最后当前页值。
    func originalValue(row: RowIdentity, column: String) -> CellValue? {
        if let change = pending.change(for: row) {
            if change.kind == .insert { return nil }
            if let base = change.baseValues[column] { return base }
        }
        return databaseValue(row: row, column: column)
    }

    /// 该行该列当前应显示的值（暂存的新值优先）。
    func currentValue(row: RowIdentity, column: String) -> CellValue? {
        if let change = pending.change(for: row) {
            switch change.kind {
            case .insert:
                return change.values[column] ?? .null
            case .update:
                if let value = change.values[column] { return value }
            case .delete:
                break
            }
        }
        return databaseValue(row: row, column: column)
    }

    /// 该行该列是否仍是截断值。
    func isTruncated(row: RowIdentity, column: String) -> Bool {
        pageRow(for: row)?.truncatedLengths[column] != nil
    }

    // MARK: - 内部：行 / 值

    private func pageRow(for identity: RowIdentity) -> TableDataRow? {
        page?.rows.first { $0.identity == identity }
    }

    private func columnIndex(_ column: String) -> Int? { columnIndexByName[column] }

    private func merged(_ row: TableDataRow) -> TableDataRow {
        guard let change = pending.change(for: row.identity), change.kind == .update else { return row }
        var merged = row
        for (column, value) in change.values {
            if let index = columnIndex(column), index < merged.values.count {
                merged.values[index] = value
            }
        }
        return merged
    }

    private func insertedRow(identity: RowIdentity,
                             change: PendingRowChange,
                             structure: TableStructure) -> TableDataRow {
        let values = structure.columns.map { change.values[$0.name] ?? .null }
        return TableDataRow(identity: identity, values: values, truncatedLengths: [:])
    }

    private func databaseValue(row: RowIdentity, column: String) -> CellValue? {
        if let loaded = fullValues[row]?[column] { return loaded }
        guard let pageRow = pageRow(for: row), let index = columnIndex(column), index < pageRow.values.count else {
            return nil
        }
        return pageRow.values[index]
    }

    private func locator(for row: RowIdentity, structure: TableStructure) -> RowLocator {
        let primaryKeys = structure.primaryKeyColumns
        guard !primaryKeys.isEmpty, let pageRow = pageRow(for: row) else {
            return RowLocator(columns: [], values: [])
        }
        var columns: [String] = []
        var values: [CellValue] = []
        for column in primaryKeys {
            guard let index = columnIndex(column.name), index < pageRow.values.count else {
                return RowLocator(columns: [], values: [])
            }
            columns.append(column.name)
            values.append(pageRow.values[index])
        }
        return RowLocator(columns: columns, values: values)
    }

    /// 按当前页顺序排序；不在页内的（新增行）排在后面。
    private func ordered(_ rows: Set<RowIdentity>) -> [RowIdentity] {
        let pageOrder = Dictionary(
            uniqueKeysWithValues: (page?.rows ?? []).enumerated().map { ($0.element.identity, $0.offset) }
        )
        return rows.sorted { lhs, rhs in
            let left = pageOrder[lhs] ?? Int.max
            let right = pageOrder[rhs] ?? Int.max
            if left != right { return left < right }
            return (lhs.keyString ?? lhs.insertID?.uuidString ?? "")
                < (rhs.keyString ?? rhs.insertID?.uuidString ?? "")
        }
    }

    // MARK: - 内部：状态同步

    private func updateEditability() {
        guard let structure else {
            editability = isReadOnlyConnection ? .readOnlyConnection : .editable
            return
        }
        if structure.kind == .view {
            editability = .view
        } else if structure.primaryKeyColumns.isEmpty {
            editability = .noPrimaryKey
        } else if isReadOnlyConnection {
            editability = .readOnlyConnection
        } else {
            editability = .editable
        }
    }

    private func pruneSelection() {
        var available = Set((page?.rows ?? []).map(\.identity))
        for change in pending.changes where change.kind == .insert {
            available.insert(change.identity)
        }
        selectedRows = Set(selectedRows.filter { available.contains($0) })
        if let focusedRow, !available.contains(focusedRow) {
            self.focusedRow = nil
            focusedColumn = nil
        }
        fullValues = fullValues.filter { available.contains($0.key) }
    }

    private func pendingDidChange() {
        objectWillChange.send()
        onPendingChangeStateChanged(pending.isEmpty)
    }

    // MARK: - 内部：持久化

    private func savePresentationState() {
        guard preferences.rememberTableState || preferences.rememberTableFilters else { return }
        var state = tableState.state(connectionID: connectionID, table: ref)
        if preferences.rememberTableState {
            state.pageSize = pageSize
            state.columnWidths = columnWidths
            state.hiddenColumns = hiddenColumns
            state.sort = sort
        }
        if preferences.rememberTableFilters {
            state.filter = filter
        }
        tableState.save(state, connectionID: connectionID, table: ref)
    }

    // MARK: - 内部：错误

    private func mapError(_ error: Error) -> MySQLError {
        if let mySQL = error as? MySQLError { return mySQL }
        return .internalError(String(describing: error))
    }

    private static func placeholderStructure(for ref: TableRef) -> TableStructure {
        TableStructure(
            ref: ref,
            kind: .table,
            comment: nil,
            columns: [],
            indexes: [],
            foreignKeys: [],
            triggers: [],
            createStatement: ""
        )
    }
}

// MARK: - 纯函数（可单元测试）

/// 表数据 ViewModel 里不依赖 IO 的逻辑。见 docs/tech-designs/07-data-grid.md §3.1、§7。
enum TableDataViewModelLogic {

    /// 大字段自动加载的合计字节上限（8 MB）。见 docs/tech-designs/14-row-inspector.md §6。
    static let autoLoadByteLimit = 8 * 1024 * 1024
    /// 每页行数上限（specs/03 §2）。
    static let maxPageSize = 10_000
    /// 深翻页提示阈值（L11）。
    static let deepOffsetThreshold = 100_000

    static func shouldAutoLoadFullValues(totalBytes: Int) -> Bool {
        totalBytes <= autoLoadByteLimit
    }

    static func isDeepOffset(pageIndex: Int, pageSize: Int) -> Bool {
        max(pageIndex, 0) * max(pageSize, 0) > deepOffsetThreshold
    }

    /// 复制行：跳过自增列与生成列，其余按值复制。
    static func duplicateColumnValues(columns: [TableColumn],
                                      values: [String: CellValue]) -> [String: CellValue] {
        var output: [String: CellValue] = [:]
        for column in columns {
            guard !column.isAutoIncrement, !column.isGenerated else { continue }
            if let value = values[column.name] { output[column.name] = value }
        }
        return output
    }

    /// `行 1–300`；rowCount 为 0 时返回 `行 0`。
    static func rowRangeText(pageIndex: Int, pageSize: Int, rowCount: Int) -> String {
        guard rowCount > 0 else { return "行 0" }
        let start = max(pageIndex, 0) * max(pageSize, 0) + 1
        let end = start + rowCount - 1
        return "行 \(groupedDigits(start))–\(groupedDigits(end))"
    }

    /// `约 12,480 行` / `12,480 行` / `约 0 行（估算不可靠）` / `行数未知`。
    static func rowCountText(estimate: UInt64?, isExact: Bool) -> String {
        guard let estimate else { return "行数未知" }
        let count = Int(clamping: estimate)
        if isExact { return "\(groupedDigits(count)) 行" }
        if count == 0 { return "约 0 行（估算不可靠）" }
        return "约 \(groupedDigits(count)) 行"
    }

    /// 每三位加逗号（确定性，不依赖 locale）。
    static func groupedDigits(_ value: Int) -> String {
        guard value != 0 else { return "0" }
        let negative = value < 0
        var digits = String(value.magnitude)
        var output = ""
        while digits.count > 3 {
            let split = digits.index(digits.endIndex, offsetBy: -3)
            output = "," + digits[split...] + output
            digits = String(digits[..<split])
        }
        output = digits + output
        return negative ? "-" + output : output
    }
}
