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
/// - 首屏只取当前页（`LIMIT pageSize + 1`），行数用估算，**绝不自动 `COUNT(*)`**（§3.4）；
/// - 大字段两阶段加载：首屏 `LEFT(col, N)` + 长度列，按需 `selectRowByKey` 取完整值；
///   截断值绝不会写回数据库（`08-pending-changes.md` §9），T8 只读但模型已区分；
/// - 排序 / 分页 / 过滤 / 隐藏列状态写回 `Tab`，随 `session.json` 往返。
@MainActor
@Observable
public final class TableDataViewModel {

    // MARK: 标识

    public let session: ConnectionSession
    public let tab: Tab
    public let database: String
    public let table: String

    @ObservationIgnored private let metadataProvider: any TableDataMetadataProviding
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let clock: Clock

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
    public private(set) var createStatement: String?
    public private(set) var isMetadataLoaded = false

    public var primaryKeySet: Set<String> { Set(primaryKeyColumns) }

    // MARK: 数据

    public private(set) var rows: [GridRow] = []
    public private(set) var loadState: TableDataLoadState = .idle
    public private(set) var hasNextPage = false
    public private(set) var lastQueryMilliseconds: Int?
    public private(set) var rowCountEstimate: RowCountEstimate?
    public private(set) var isCountingExact = false

    // MARK: 查询状态（与 Tab 同步）

    public private(set) var pageIndex: Int
    public private(set) var pageSize: Int
    public private(set) var sortOrders: [SortOrder]
    public private(set) var hiddenColumns: Set<String>
    public private(set) var filter: FilterState?
    public private(set) var columnWidths: [String: Double]

    // MARK: 选择

    public private(set) var focusedRowID: String?
    public private(set) var focusedColumn: String?
    public private(set) var selectedRowIDs: Set<String> = []

    // MARK: 大字段二次加载

    public private(set) var isLoadingFullRow = false
    public private(set) var manualFullLoadRequired = false
    public private(set) var fullRowError: String?
    @ObservationIgnored private var fullRowCache: [String: [String: SQLValue]] = [:]

    // MARK: 复制提示

    public private(set) var copyNotice: String?
    @ObservationIgnored private var copyNoticeTask: Task<Void, Never>?

    // MARK: 修订号（驱动 AppKit 桥接增量刷新）

    /// 数据 / 列 / 布局变化时自增；选中变化不自增。
    public private(set) var dataRevision = 0

    // MARK: 内部

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var fullLoadTask: Task<Void, Never>?
    @ObservationIgnored private var persistTask: Task<Void, Never>?

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
        // 新标签的 PageState 是默认值；此时用偏好里的「每页行数」。
        if tab.page.pageSize == PageSize.default {
            self.pageSize = preferences.pageSize
        } else {
            self.pageSize = tab.page.pageSize
        }
        self.pageIndex = tab.page.pageIndex
        self.sortOrders = tab.sort
        self.hiddenColumns = Set(tab.hiddenColumns)
        self.filter = tab.filter
        self.columnWidths = session.tableLayout(database: self.database, table: self.table)?.columnWidths ?? [:]
    }

    // MARK: 生命周期

    /// 首次进入标签时加载：元数据 → 当前页。
    public func start() async {
        guard !didStart else { return }
        didStart = true
        await loadMetadata(force: false)
        guard isMetadataLoaded else { return }
        await performPageQuery()
    }

    /// 重新加载当前页（`⌘R` / 刷新）；清空大字段缓存（`specs/03-data-browsing.md` §12）。
    public func refresh() async {
        fullRowCache.removeAll()
        await loadMetadata(force: true)
        guard isMetadataLoaded else { return }
        await performPageQuery()
    }

    /// 重新查询当前页，不清元数据缓存。
    public func reloadCurrentPage() async {
        guard isMetadataLoaded else {
            await start()
            return
        }
        await performPageQuery()
    }

    /// 供视图 `onDisappear` 调用的取消入口：标签关闭时中断在途查询。
    public func cancelInFlight() {
        activeTask?.cancel()
        activeTask = nil
        fullLoadTask?.cancel()
        fullLoadTask = nil
        persistTask?.cancel()
        persistTask = nil
        Task { await session.cancelCurrentQuery() }
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

    public var pageState: PageState {
        PageState(pageIndex: pageIndex, pageSize: pageSize, rowCount: rowCountEstimate)
    }

    public var focusedRow: GridRow? {
        guard let focusedRowID else { return nil }
        return rows.first { $0.id == focusedRowID }
    }

    public var focusedColumnInfo: ColumnInfo? {
        guard let focusedColumn else { return nil }
        return columns.first { $0.name == focusedColumn }
    }

    /// 状态栏文案：`行 1–300 / 约 12,480 行 · 第 1 页 · 300 行/页 · 128 ms`。
    public var statusBarText: String? {
        guard loadState == .loaded || !rows.isEmpty else { return nil }
        var text = pageState.statusText(visibleCount: rows.count)
        if let milliseconds = lastQueryMilliseconds {
            text += " · \(milliseconds) ms"
        }
        return text
    }

    public var isDeepOffset: Bool { pageState.isDeepOffset }

    public var deepOffsetHint: String? {
        guard isDeepOffset else { return nil }
        return "偏移量很大，翻页会越来越慢；建议用过滤器缩小范围后再翻页"
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
        primaryKeyColumns.isEmpty ? "该表没有主键，分页顺序不保证，且不可编辑" : nil
    }

    public var isFilterVisible: Bool { filter?.isVisible ?? false }

    public var cellDisplayContext: CellDisplayContext {
        CellDisplayContext(
            nullText: preferences.nullDisplayText,
            tinyintAsCheckbox: preferences.tinyintAsCheckbox
        )
    }

    // MARK: 排序

    /// 点列头：无 → 升序 → 降序 → 无；`⇧` 点击追加多列排序。
    public func toggleSort(column: String, additive: Bool) {
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
        pageIndex = 0
        syncTab()
        bumpRevision()
        startQuery()
    }

    // MARK: 分页

    public func goToNextPage() {
        guard hasNextPage else { return }
        pageIndex += 1
        syncTab()
        bumpRevision()
        startQuery()
    }

    public func goToPreviousPage() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
        syncTab()
        bumpRevision()
        startQuery()
    }

    public func goToPage(_ index: Int) {
        let target = max(0, index)
        guard target != pageIndex else { return }
        pageIndex = target
        syncTab()
        bumpRevision()
        startQuery()
    }

    public func setPageSize(_ size: Int) {
        guard PageSize.isValid(size), size != pageSize else { return }
        pageSize = size
        pageIndex = 0
        preferences.pageSize = size
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
                let result = try await self.session.execute(sql, database: self.database)
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

    // MARK: 过滤（T10 接入口）

    public func setFilter(_ state: FilterState?) {
        filter = state
        tab.filter = state
        pageIndex = 0
        syncTab()
        bumpRevision()
        startQuery()
    }

    public func setFilterVisible(_ visible: Bool) {
        var state = filter ?? FilterState()
        state.isVisible = visible
        filter = state
        tab.filter = state
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
        if let focusedRowID, let row = rows.first(where: { $0.id == focusedRowID }) {
            return row
        }
        if let id = selectedRowIDs.first {
            return rows.first { $0.id == id }
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
        guard let row = rows.first(where: { $0.id == rowID }),
              let cell = row.cells[column],
              cell.needsFullValueLoad else { return }
        fullLoadTask?.cancel()
        fullLoadTask = nil
        await performFullRowLoad(force: true, targetRowID: rowID)
    }

    private func performFullRowLoad(force: Bool, targetRowID: String?) async {
        let row: GridRow?
        if let targetRowID {
            row = rows.first { $0.id == targetRowID }
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
            let result = try await session.execute(query.sql, database: database)
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
        guard let row = rows.first(where: { $0.id == rowID }) else { return CopyResult(text: "") }
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
            let selected = rows.filter { selectedRowIDs.contains($0.id) }
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
        let notice = copiedRows.count > Self.copyNoticeRowThreshold
            ? "已复制 \(RowCountEstimate.grouped(Int64(copiedRows.count))) 行（\(ByteSize.format(text.utf8.count))）"
            : nil
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

    // MARK: 快速查看

    /// 构建快速查看内容；`isLoading == true` 表示需要先二次加载。
    public func quickLookContent(rowID: String, column: String) -> QuickLookContent? {
        guard let columnInfo = columns.first(where: { $0.name == column }),
              let row = rows.first(where: { $0.id == rowID }),
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
        return try? FilterSQLBuilder.whereClause(
            for: filter,
            columns: columns,
            escaping: queryOptions.escaping,
            introducer: queryOptions.introducer
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
            await self?.performPageQuery()
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

    // MARK: 当前页查询

    private func performPageQuery() async {
        guard isMetadataLoaded else { return }
        loadState = .loading

        let options = queryOptions
        let query = TableQueryBuilder.selectPage(
            database: database,
            table: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            sort: sortOrders,
            filterClause: filterClause,
            pageIndex: pageIndex,
            pageSize: pageSize,
            options: options
        )

        let started = clock.now
        do {
            let result = try await session.execute(query.sql, database: database)
            if Task.isCancelled { return }
            lastQueryMilliseconds = max(0, Int(clock.now.timeIntervalSince(started) * 1000))

            guard let resultSet = result.firstResultSet else {
                rows = []
                hasNextPage = false
                loadState = .loaded
                syncTab()
                bumpRevision()
                return
            }

            let parsed = makeRows(from: resultSet, query: query, options: options)
            hasNextPage = parsed.count > pageSize
            let visible = Array(parsed.prefix(pageSize))

            // 页码越界（删除 / 过滤后）：回到第一页。
            if visible.isEmpty, pageIndex > 0, parsed.isEmpty {
                pageIndex = 0
                loadState = .loaded
                syncTab()
                bumpRevision()
                await performPageQuery()
                return
            }

            rows = visible
            if let focused = focusedRowID, !rows.contains(where: { $0.id == focused }) {
                // 刷新后焦点行不在本页：保留本页仍存在的选中项，清掉焦点行。
                focusedRowID = nil
            }
            if !selectedRowIDs.isEmpty {
                let present = Set(rows.map(\.id))
                selectedRowIDs = selectedRowIDs.intersection(present)
            }
            if let cached = focusedRowID, let map = fullRowCache[cached] {
                applyFullValues(map, toRowID: cached)
            }
            loadState = .loaded
            syncTab()
            bumpRevision()
        } catch {
            if Task.isCancelled { return }
            rows = []
            hasNextPage = false
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
            let identity = locator?.identityString ?? "row:\(pageIndex * pageSize + rowOffset)"
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
        var page = tab.page
        page.pageIndex = pageIndex
        page.pageSize = pageSize
        page.rowCount = rowCountEstimate
        tab.page = page
        tab.sort = sortOrders
        tab.filter = filter
        tab.hiddenColumns = columns.map(\.name).filter { hiddenColumns.contains($0) }
        tab.focusedColumn = focusedColumn
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

    private func bumpRevision() {
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
