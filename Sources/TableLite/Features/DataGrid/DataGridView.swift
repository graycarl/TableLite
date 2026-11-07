import SwiftUI
import AppKit

// MARK: - NSTableView 桥接

/// 数据网格：`NSViewRepresentable` 包装 `NSTableView`（view-based）。
///
/// 为什么用 AppKit 见 `docs/tech-designs/07-data-grid.md` §1。
/// 网格**只读**：单元格不承载编辑器，所有值修改都在右侧字段栏（T9）。
///
/// 性能约定（`06-ui-layer.md` §4）：`updateNSView` 按修订号增量刷新，
/// 不因为一次选中变化就 `reloadData`；列变化与数据变化才全量 reload。
struct DataGridView: NSViewRepresentable {

    let viewModel: TableDataViewModel
    let preferences: Preferences
    /// 触发快速查看时把内容交给上层展示（上层负责 `NSPanel`）。
    var onQuickLook: (QuickLookContent) -> Void
    /// 「导出选中行…」入口（`specs/08-import-export.md` §1）：把导出源上抛给上层。
    var onExport: ((ExportSource) -> Void)?

    func makeCoordinator() -> DataGridCoordinator {
        DataGridCoordinator(viewModel: viewModel, preferences: preferences, onQuickLook: onQuickLook, onExport: onExport)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = DataGridTableView()
        tableView.gridCoordinator = coordinator
        coordinator.tableView = tableView
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        // 不画网格线：分行靠隔行变色（`docs/tech-designs/07-data-grid.md` §4）。
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.rowHeight = coordinator.rowHeight
        tableView.target = coordinator
        tableView.action = #selector(DataGridCoordinator.tableViewClicked(_:))
        tableView.doubleAction = #selector(DataGridCoordinator.tableViewDoubleClicked(_:))
        tableView.setAccessibilityLabel("表数据网格")
        tableView.setAccessibilityIdentifier("grid.table")

        let headerView = GridHeaderView()
        headerView.coordinator = coordinator
        tableView.headerView = headerView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = preferences.autoHideScrollers
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppNSColor.content
        // 横向滚动 / 窗口缩放要重算列窗口（见 §10.2 的水平列虚拟化）。
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(DataGridCoordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        coordinator.rebuildColumns()
        coordinator.reloadAll()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.onQuickLook = onQuickLook
        context.coordinator.onExport = onExport
        context.coordinator.sync()
    }
}

// MARK: - 协调器

/// 实现 `NSTableViewDataSource` / `NSTableViewDelegate`，
/// 把手势与选中转成对 ViewModel 的调用（`06-ui-layer.md` §4）。
@MainActor
final class DataGridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    static let rowNumberIdentifier = NSUserInterfaceItemIdentifier("__mtl_row_number__")

    var viewModel: TableDataViewModel
    var preferences: Preferences
    var onQuickLook: (QuickLookContent) -> Void
    var onExport: ((ExportSource) -> Void)?
    weak var tableView: DataGridTableView?

    private var lastDataRevision = -1
    private var lastFontSize = -1
    private var lastAlternateRowColors: Bool?
    private var lastColumnSignature = ""
    private var didEstimateWidths = false
    private var isApplyingSelection = false
    /// 列名 → 列元数据。`viewFor` 是热路径，避免每个单元格都线性扫 `columns`。
    private var columnsByName: [String: ColumnInfo] = [:]
    /// 行序列快照的缓存（`rows + insertionRows`）与它对应的修订号。
    private var cachedRows: [GridRow] = []
    private var cachedRowsRevision = Int.min

    // MARK: 水平列虚拟化（`07-data-grid.md` §10.2）
    //
    // AppKit 的 view-based `NSTableView` 会为「可见行范围 × **全部列**」物化 cell 视图，
    // 宽表下实测 96% 的常驻单元格在屏幕外。这里只对「与水平可视区相交（含 overscan 一个
    // 视口宽）」的列物化，其余 `viewFor` 返回 `nil`；水平可视区变化时做一次局部重载把新
    // 进视野的列补上。

    /// 当前物化的列下标区间；`nil` 表示「还没拿到可视区」或「列窗口为空」，此时全量物化。
    private var columnWindow: ClosedRange<Int>?
    /// 列 identifier → 下标；`viewFor` 是热路径，窗口判定必须 O(1)。
    private var columnIndexByIdentifier: [NSUserInterfaceItemIdentifier: Int] = [:]
    /// 重算窗口时正在重载自身，避免 `reloadData` 的几何变化再次触发。
    private var isRefreshingColumnWindow = false

    /// 水平 overscan：可视列数左右各多物化四分之一，横向滚动时不必每滚一点就重载。
    ///
    /// 早先按「一个视口宽」扩展，那时列宽是粗估的、都偏宽，一屏列数少，代价不明显。
    /// 列宽改成按内容量之后窄列变多（200 列的表一屏能看到 26 列），按视口扩展等于物化 78 列，
    /// 滚动 p50 从 16.7ms 掉到 31ms；改成按列数扩展（26 ± 6）才回到 16.7ms
    /// （`07-data-grid.md` §10.2）。
    private static let columnWindowOverscanRatio = 0.25
    /// 至少多物化两列，免得宽列表面上刚好只多一列、横向一滚就要重载。
    private static let columnWindowMinimumOverscan = 2

    /// 当前加载的行序列快照。
    ///
    /// `viewModel.gridRows` 每次访问都会重新拼接数组，热路径不能反复调用；
    /// 用修订号做失效判断，数据没变时只是整型比较 + 数组引用计数，没有拷贝。
    private var rowsSnapshot: [GridRow] {
        if cachedRowsRevision != viewModel.dataRevision {
            cachedRowsRevision = viewModel.dataRevision
            cachedRows = viewModel.gridRows
        }
        return cachedRows
    }
    /// 当前焦点列（网格自己维护；键盘 ← → 与点击都会更新）。
    private var focusedColumnName: String?
    private var contextRow: Int = -1
    private var contextColumn: Int = -1

    init(
        viewModel: TableDataViewModel,
        preferences: Preferences,
        onQuickLook: @escaping (QuickLookContent) -> Void,
        onExport: ((ExportSource) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.preferences = preferences
        self.onQuickLook = onQuickLook
        self.onExport = onExport
        self.focusedColumnName = viewModel.focusedColumn ?? viewModel.visibleColumns.first?.name
        super.init()
    }

    // MARK: 字体

    var cellFont: NSFont {
        NSFont.systemFont(ofSize: CGFloat(preferences.gridFontSize))
    }

    var rowHeight: CGFloat {
        max(AppMetrics.tableRowHeight, CGFloat(preferences.gridFontSize) + 13)
    }

    // MARK: 同步

    func sync() {
        guard let tableView else { return }
        tableView.enclosingScrollView?.autohidesScrollers = preferences.autoHideScrollers
        tableView.usesAlternatingRowBackgroundColors = false

        if lastFontSize != preferences.gridFontSize {
            lastFontSize = preferences.gridFontSize
            tableView.rowHeight = rowHeight
            tableView.reloadData()
            refreshGridCanvas()
        }

        if lastAlternateRowColors != preferences.alternateRowColors {
            lastAlternateRowColors = preferences.alternateRowColors
            tableView.reloadData()
            refreshGridCanvas()
        }

        let signature = columnSignature()
        if signature != lastColumnSignature {
            lastColumnSignature = signature
            rebuildColumns()
            tableView.reloadData()
            didEstimateWidths = false
        }

        if lastDataRevision != viewModel.dataRevision {
            lastDataRevision = viewModel.dataRevision
            refreshColumnIndex()
            refreshColumnWindow(reloadIfChanged: false)
            tableView.reloadData()
            applyEstimatedWidthsIfNeeded()
        }
        refreshGridCanvas()

        applySelectionFromViewModel()
    }

    func reloadAll() {
        lastDataRevision = viewModel.dataRevision
        refreshColumnIndex()
        refreshColumnWindow(reloadIfChanged: false)
        tableView?.reloadData()
        applyEstimatedWidthsIfNeeded()
        refreshGridCanvas()
    }

    /// 重建「列名 → 列元数据」索引；列清单或数据修订变化时调用。
    private func refreshColumnIndex() {
        columnsByName = Dictionary(viewModel.columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func columnSignature() -> String {
        let visible = viewModel.visibleColumns
            .map { "\($0.name)|\($0.isPrimaryKey ? "pk" : "")" }
            .joined(separator: ",")
        let sort = viewModel.sortOrders
            .map { "\($0.column):\($0.direction.rawValue)" }
            .joined(separator: ",")
        return visible + "#" + sort
    }

    // MARK: 列

    func rebuildColumns() {
        guard let tableView else { return }
        refreshColumnIndex()
        columnIndexByIdentifier.removeAll(keepingCapacity: true)
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }

        let rowColumn = NSTableColumn(identifier: Self.rowNumberIdentifier)
        rowColumn.title = "#"
        rowColumn.width = 48
        rowColumn.minWidth = 36
        rowColumn.maxWidth = 80
        rowColumn.resizingMask = []
        rowColumn.isEditable = false
        rowColumn.headerToolTip = "行号"
        tableView.addTableColumn(rowColumn)

        let headerFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for column in viewModel.visibleColumns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.name))
            tableColumn.headerCell.attributedStringValue = headerTitle(for: column, baseFont: headerFont)
            tableColumn.headerToolTip = column.gridTypeTooltip
            tableColumn.width = viewModel.columnWidths[column.name] ?? fallbackWidth(for: column)
            tableColumn.minWidth = 40
            tableColumn.maxWidth = 2000
            tableColumn.resizingMask = .userResizingMask
            tableColumn.isEditable = false
            tableView.addTableColumn(tableColumn)
        }
        columnIndexByIdentifier = Dictionary(
            tableView.tableColumns.enumerated().map { ($0.element.identifier, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        // 列集合变了，x 映射也变了：重新判定列窗口（不触发重载，调用方随后会 `reloadData`）。
        refreshColumnWindow(reloadIfChanged: false)
        // 画布在行视图之下：重载时行视图会被重新添加，画布必须重新压到底。
        if gridCanvas.superview !== tableView {
            tableView.addSubview(gridCanvas, positioned: .below, relativeTo: nil)
        }
        lastCanvasRowsHeight = -1
        refreshGridCanvas()
        refreshColumnSeparators()
    }

    private func headerTitle(for column: ColumnInfo, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // 主键列只加粗，不加图标（`specs/03-data-browsing.md` §1）：表头文案本身就是字段名。
        var text = column.name
        if let index = viewModel.sortOrders.firstIndex(where: { $0.column == column.name }) {
            let direction = viewModel.sortOrders[index].direction
            let marker = viewModel.sortOrders.count > 1 ? "\(direction.arrow)\(index + 1)" : direction.arrow
            text += " \(marker)"
        }
        let font: NSFont = column.isPrimaryKey
            ? NSFont.boldSystemFont(ofSize: baseFont.pointSize)
            : baseFont
        result.append(NSAttributedString(string: text, attributes: [.font: font]))
        return result
    }

    /// 还没量到内容时的占位宽度：只按列头文字量（`GridColumnWidth`）。
    private func fallbackWidth(for column: ColumnInfo) -> CGFloat {
        GridColumnWidth.fit(texts: [column.name], font: cellFont)
    }

    /// 首次拿到数据后按「现在看得见的那些行的显示值 + 列头」量列宽
    /// （`specs/03-data-browsing.md` §5、`docs/tech-designs/07-data-grid.md` §4.1）。
    ///
    /// - 只采样可见行：一屏之外的数据不该把列拽宽，用户眼下看不到的东西没有发言权。
    /// - 用真实字体量（`GridColumnWidth`），不再用「字符数 × 8pt」。
    /// - 用户拖过的列不参与（`hasUserWidth`），自动量出来的宽度也不冒充用户宽度。
    private func applyEstimatedWidthsIfNeeded() {
        // 等真有数据再量：首帧 `rowsSnapshot` 还是空的，那时量出来只有列头宽度，之后又不会重量。
        guard !didEstimateWidths, !rowsSnapshot.isEmpty, let tableView else { return }
        didEstimateWidths = true
        let context = viewModel.cellDisplayContext
        let sampleRows = widthSampleRows(in: tableView)
        var estimated: [String: Double] = [:]
        for tableColumn in tableView.tableColumns where tableColumn.identifier != Self.rowNumberIdentifier {
            let name = tableColumn.identifier.rawValue
            guard let column = columnsByName[name], !viewModel.hasUserWidth(name) else { continue }
            var texts = [column.name]
            texts.reserveCapacity(sampleRows.count + 1)
            for row in sampleRows {
                guard row >= 0, row < rowsSnapshot.count,
                      let cell = rowsSnapshot[row].cells[name] else { continue }
                texts.append(
                    CellDisplayFormatter.display(
                        value: cell.displayValue,
                        isTruncated: cell.isTruncated && cell.fullValue == nil,
                        totalByteCount: cell.totalByteCount,
                        column: column,
                        context: context
                    ).text
                )
            }
            let width = GridColumnWidth.fit(texts: texts, font: cellFont)
            applyEstimatedWidth(width, to: tableColumn)
            estimated[name] = Double(width)
        }
        viewModel.setEstimatedColumnWidths(estimated)
        // 列宽变了 → x 映射变了，列窗口与竖线都要重算。
        refreshColumnSeparators()
        refreshColumnWindow()
    }

    /// 采样用的行号：优先当前可见范围；还没上屏（首次布局）时退回前 50 行。
    private func widthSampleRows(in tableView: NSTableView) -> [Int] {
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 0 {
            return Array(visible.location ..< (visible.location + visible.length))
        }
        return Array(0 ..< min(rowsSnapshot.count, 50))
    }

    /// 把自动量出来的宽度写到列上：不经过「用户拖拽」这条路，所以不标记为 `userResizedColumns`。
    private func applyEstimatedWidth(_ width: CGFloat, to tableColumn: NSTableColumn) {
        isApplyingEstimatedWidth = true
        tableColumn.width = width
        isApplyingEstimatedWidth = false
    }

    // MARK: 列窗口

    /// 按当前几何算出应当物化的列下标区间；返回 `nil` 表示无法判定（尚未参与布局），
    /// 此时退回全量物化。
    private func computeColumnWindow(_ tableView: NSTableView) -> ClosedRange<Int>? {
        // 还没上屏（`NSViewRepresentable` 刚装配）时几何不可信：返回 nil，等首帧后再重算，
        // 那时会走「首次拿到窗口 → 整表重建」的分支。
        guard tableView.window != nil else { return nil }
        let visible = tableView.visibleRect
        guard visible.width > 0, visible.height > 0, !tableView.tableColumns.isEmpty else { return nil }
        // 先量「真正可见的列」，再按列数向两侧扩展。
        var firstVisible: Int?
        var lastVisible: Int?
        for index in tableView.tableColumns.indices {
            let frame = tableView.rect(ofColumn: index)
            if frame.maxX <= visible.minX { continue }
            if frame.minX >= visible.maxX { break }
            if firstVisible == nil { firstVisible = index }
            lastVisible = index
        }
        guard let firstVisible, let lastVisible else { return nil }
        let visibleCount = lastVisible - firstVisible + 1
        let overscan = max(Self.columnWindowMinimumOverscan, Int(Double(visibleCount) * Self.columnWindowOverscanRatio))
        let lower = max(0, firstVisible - overscan)
        let upper = min(tableView.tableColumns.count - 1, lastVisible + overscan)
        return lower...upper
    }

    /// 重算列窗口。窗口变了且 `reloadIfChanged` 为真时，只对「可见行 × 新旧列窗口并集」
    /// 做局部重载：新进视野的列补上视图，离开视野的列交还给复用队列。
    private func refreshColumnWindow(reloadIfChanged: Bool = true) {
        guard let tableView, !isRefreshingColumnWindow else { return }
        let updated = computeColumnWindow(tableView)
        guard updated != columnWindow else { return }
        let previous = columnWindow
        columnWindow = updated
        guard reloadIfChanged, let updated else { return }

        isRefreshingColumnWindow = true
        defer { isRefreshingColumnWindow = false }
        guard let previous else {
            // 首次拿到可视区：此前是「无法判定 → 全量物化」，整表重建一次把它们丢掉。
            tableView.reloadData()
            return
        }
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.length > 0 else { return }
        let lower = min(previous.lowerBound, updated.lowerBound)
        let upper = max(previous.upperBound, updated.upperBound)
        guard lower >= 0, upper < tableView.tableColumns.count else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)),
            columnIndexes: IndexSet(integersIn: lower...upper)
        )
    }

    @objc func clipViewBoundsDidChange(_ notification: Notification) {
        refreshColumnWindow()
    }

    deinit {
        // 通知中心对观察者是弱引用，这里只是把手尾清理干净。
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: 数据源

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowsSnapshot.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row >= 0, row < rowsSnapshot.count else { return nil }
        // 水平虚拟化：窗口外的列不物化视图（`07-data-grid.md` §10.2）。
        if let window = columnWindow,
           let columnIndex = columnIndexByIdentifier[tableColumn.identifier],
           !window.contains(columnIndex) {
            return nil
        }
        let gridRow = rowsSnapshot[row]
        let isSelected = tableView.selectedRowIndexes.contains(row)

        if tableColumn.identifier == Self.rowNumberIdentifier {
            let cell = rowNumberCell(tableView)
            let number = row + 1
            cell.textField?.stringValue = gridRow.changeKind?.marker ?? String(number)
            return cell
        }

        guard let column = columnsByName[tableColumn.identifier.rawValue],
              let cellModel = gridRow.cells[column.name] else {
            return nil
        }
        let display = CellDisplayFormatter.display(
            value: cellModel.displayValue,
            isTruncated: cellModel.isTruncated && cellModel.fullValue == nil,
            totalByteCount: cellModel.totalByteCount,
            column: column,
            context: viewModel.cellDisplayContext
        )
        let cell = cellView(tableView, identifier: tableColumn.identifier)
        // 外键列且本行该列非 NULL 时追加 `↗`（`specs/03-data-browsing.md` §10）。
        let isForeignKey = viewModel.foreignKeyColumns.contains(column.name) && !cellModel.displayValue.isNull
        cell.configure(
            display: display,
            font: cellFont,
            isSelected: isSelected,
            changeKind: gridRow.changeKind,
            isEdited: cellModel.isEdited,
            isForeignKey: isForeignKey
        )
        return cell
    }

    /// 正在写入自动估算的宽度：此时 `tableViewColumnDidResize` 不该把它当成用户拖拽。
    private var isApplyingEstimatedWidth = false

    /// 底纹 / 网格线的画布：一次绘制，不按行重复（`07-data-grid.md` §4.1）。
    let gridCanvas = GridCanvasView()

    /// 画布的行区域高度；`sync()` 每次 SwiftUI 更新都会走到刷新，不能无条件标脏。
    private var lastCanvasRowsHeight: CGFloat = -1

    /// 画布的位置与行区域。只在真变了的时候重画 —— 每帧无条件 `needsDisplay` 等于每帧整块重绘。
    private func refreshGridCanvas() {
        guard let tableView, gridCanvas.superview === tableView else { return }
        let step = tableView.rowHeight + tableView.intercellSpacing.height
        let rowsHeight = CGFloat(rowsSnapshot.count) * step
        var changed = false
        if abs(rowsHeight - lastCanvasRowsHeight) > 0.5 {
            lastCanvasRowsHeight = rowsHeight
            let region = NSRect(x: 0, y: 0, width: tableView.bounds.width, height: rowsHeight)
            gridCanvas.frame = region
            gridCanvas.rowsRect = region
            changed = true
        }
        gridCanvas.ownerTableView = tableView
        let stripesOn = preferences.alternateRowColors
        if (gridCanvas.stripeColor != nil) != stripesOn {
            gridCanvas.stripeColor = stripesOn ? AppNSColor.rowAlternate : nil
            changed = true
        }
        if changed { gridCanvas.needsDisplay = true }
    }

    /// 列的竖线 x 坐标。只有列集合 / 列宽 / 列显隐变了才重算
    /// （200 列的表上 `rect(ofColumn:)` 要跑 200 次，不能放进 `sync()` 的每帧路径）。
    private func refreshColumnSeparators() {
        guard let tableView else { return }
        let columns = tableView.tableColumns
        var xs: [CGFloat] = []
        xs.reserveCapacity(columns.count)
        // 画在每一列的右缘（含行号列），最后一列右缘不画 —— 那里是表格外边。
        for (index, column) in columns.enumerated() where !column.isHidden && index < columns.count - 1 {
            xs.append((tableView.rect(ofColumn: index).maxX - 1).rounded(.down))
        }
        guard xs != gridCanvas.columnSeparatorXs else { return }
        gridCanvas.columnSeparatorXs = xs
        gridCanvas.needsDisplay = true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("GridRowView")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? TableRowView
            ?? {
                let made = TableRowView()
                made.identifier = identifier
                return made
            }()
        rowView.fillColor = rowBackgroundColor(for: row)
        return rowView
    }

    /// 新增 / 修改 / 删除行的整行底色（`specs/03-data-browsing.md` §4、`specs/04-data-editing.md` §3）。
    private func rowBackgroundColor(for row: Int) -> NSColor? {
        guard row >= 0, row < rowsSnapshot.count else { return nil }
        switch rowsSnapshot[row].changeKind {
        case .insertion: return NSColor.systemGreen.withDynamicAlpha(0.12)
        case .update: return NSColor.systemYellow.withDynamicAlpha(0.10)
        case .deletion: return NSColor.systemRed.withDynamicAlpha(0.10)
        case nil: return nil
        }
    }

    private func rowNumberCell(_ tableView: NSTableView) -> NSTableCellView {
        if let reused = tableView.makeView(withIdentifier: Self.rowNumberIdentifier, owner: self) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = Self.rowNumberIdentifier
        let field = NSTextField(labelWithString: "")
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: max(9, cellFont.pointSize - 1), weight: .regular)
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func cellView(_ tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier) -> GridCellView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? GridCellView {
            return reused
        }
        let cell = GridCellView()
        cell.identifier = identifier
        return cell
    }

    // MARK: 选择

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        pushSelection()
    }

    @objc func tableViewClicked(_ sender: NSTableView) {
        let column = sender.clickedColumn
        if column > 0, column < sender.tableColumns.count {
            focusedColumnName = sender.tableColumns[column].identifier.rawValue
        } else if column == 0 {
            focusedColumnName = nil
        }
        pushSelection()
    }

    @objc func tableViewDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        let column = sender.clickedColumn
        guard row >= 0, row < viewModel.gridRows.count,
              column > 0, column < sender.tableColumns.count else { return }
        let gridRow = viewModel.gridRows[row]
        let columnName = sender.tableColumns[column].identifier.rawValue
        // 可编辑表：双击跳到字段栏对应字段；不可编辑表：打开快速查看（`specs/04-data-editing.md` §2 / §3）。
        if viewModel.isEditingEnabled, gridRow.changeKind != .deletion {
            focusedColumnName = columnName
            viewModel.focusInspector(rowID: gridRow.id, column: columnName)
        } else {
            presentQuickLook(rowID: gridRow.id, column: columnName)
        }
    }

    // MARK: 行操作（T9）

    func insertRow() {
        viewModel.beginInsert()
    }

    func copySelectedRows() {
        let ids = selectedRowIDsForAction(fallbackRow: nil)
        Task { [weak self] in await self?.viewModel.copySelectedRows(rowIDs: ids) }
    }

    func deleteSelectedRows() {
        viewModel.deleteRows(rowIDs: selectedRowIDsForAction(fallbackRow: nil))
    }

    /// 右键菜单用：上下文行在选区里则作用于整个选区，否则只作用于该行。
    private func selectedRowIDsForAction(fallbackRow: Int?) -> [String] {
        if let tableView {
            let selected = tableView.selectedRowIndexes.compactMap { index -> String? in
                guard index >= 0, index < viewModel.gridRows.count else { return nil }
                return viewModel.gridRows[index].id
            }
            if let fallbackRow, fallbackRow >= 0, fallbackRow < viewModel.gridRows.count {
                let contextID = viewModel.gridRows[fallbackRow].id
                if selected.contains(contextID), !selected.isEmpty { return selected }
                return [contextID]
            }
            if !selected.isEmpty { return selected }
        }
        if let focusedRowID = viewModel.focusedRowID { return [focusedRowID] }
        return []
    }

    private func pushSelection() {
        guard let tableView else { return }
        let ids = tableView.selectedRowIndexes.compactMap { index -> String? in
            guard index >= 0, index < rowsSnapshot.count else { return nil }
            return rowsSnapshot[index].id
        }
        let focusedIndex = tableView.selectedRow
        let focusedID = (focusedIndex >= 0 && focusedIndex < rowsSnapshot.count)
            ? rowsSnapshot[focusedIndex].id
            : ids.first
        let column = focusedColumnName
        // 焦点列若被隐藏，回落到第一列。
        let resolvedColumn = column.flatMap { name in
            viewModel.visibleColumns.contains { $0.name == name } ? name : nil
        } ?? viewModel.visibleColumns.first?.name
        viewModel.updateSelection(rowIDs: ids, focusedRowID: focusedID, focusedColumn: resolvedColumn)
    }

    private func applySelectionFromViewModel() {
        guard let tableView else { return }
        let targetIDs = viewModel.selectedRowIDs
        let indexes = IndexSet(rowsSnapshot.enumerated().compactMap { index, row in
            targetIDs.contains(row.id) ? index : nil
        })
        if tableView.selectedRowIndexes != indexes {
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }
        if let focusedRowID = viewModel.focusedRowID,
           let index = rowsSnapshot.firstIndex(where: { $0.id == focusedRowID }) {
            focusedColumnName = viewModel.focusedColumn ?? focusedColumnName
            if tableView.selectedRow != index {
                isApplyingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true)
                isApplyingSelection = false
            }
        }
    }

    // MARK: 外键跳转（`specs/03-data-browsing.md` §10）

    /// `↗` 的可点击区宽度（单元格右侧）。
    static let foreignKeyHitWidth: CGFloat = 22

    /// 点击点是否落在外键行的 `↗` 上。
    func isForeignKeyArrowHit(row: Int, column: Int, point: NSPoint) -> Bool {
        guard let tableView,
              row >= 0, row < rowsSnapshot.count,
              column > 0, column < tableView.tableColumns.count else { return false }
        let name = tableView.tableColumns[column].identifier.rawValue
        guard viewModel.foreignKeyColumns.contains(name),
              let cell = rowsSnapshot[row].cells[name],
              !cell.displayValue.isNull else { return false }
        // 布尔列显示为复选框时单元格不画 `↗`，命中区也一并取消，保持视觉与可点区一致。
        if let columnInfo = columnsByName[name],
           columnInfo.isBooleanTinyInt, preferences.tinyintAsCheckbox {
            return false
        }
        let frame = tableView.frameOfCell(atColumn: column, row: row)
        return point.x >= frame.maxX - Self.foreignKeyHitWidth
    }

    /// 从网格“行 + 列”发起外键跳转（`↗`）。
    func openForeignKey(row: Int, column: Int) {
        guard let tableView,
              row >= 0, row < rowsSnapshot.count,
              column > 0, column < tableView.tableColumns.count else { return }
        let rowID = rowsSnapshot[row].id
        let columnName = tableView.tableColumns[column].identifier.rawValue
        Task { [weak self] in
            await self?.viewModel.openForeignKey(rowID: rowID, column: columnName)
        }
    }

    // MARK: 键盘与复制

    func moveFocusColumn(delta: Int) {
        let names = viewModel.visibleColumns.map(\.name)
        guard !names.isEmpty else { return }
        let current = focusedColumnName.flatMap { names.firstIndex(of: $0) } ?? 0
        let target = min(max(current + delta, 0), names.count - 1)
        focusedColumnName = names[target]
        pushSelection()
    }

    func moveFocusToFirstColumn() {
        focusedColumnName = viewModel.visibleColumns.first?.name
        pushSelection()
    }

    func moveFocusToLastColumn() {
        focusedColumnName = viewModel.visibleColumns.last?.name
        pushSelection()
    }

    /// `⌘↑`：跳到已加载数据首行（`specs/02-workspace.md` §9）。
    func moveFocusToFirstRow() {
        moveFocus(toRowIndex: 0)
    }

    /// `⌘↓`：跳到已加载数据末行（`specs/02-workspace.md` §9）。
    func moveFocusToLastRow() {
        moveFocus(toRowIndex: viewModel.gridRows.count - 1)
    }

    private func moveFocus(toRowIndex index: Int) {
        guard let tableView, !viewModel.gridRows.isEmpty,
              index >= 0, index < viewModel.gridRows.count else { return }
        if focusedColumnName == nil {
            focusedColumnName = viewModel.visibleColumns.first?.name
        }
        isApplyingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isApplyingSelection = false
        tableView.scrollRowToVisible(index)
        pushSelection()
    }

    /// `↩`：等价于双击选中单元格（可编辑表跳到字段栏，不可编辑表打开快速查看）。
    func activateFocusedCell() {
        guard let tableView,
              tableView.selectedRow >= 0, tableView.selectedRow < viewModel.gridRows.count,
              let column = focusedColumnName ?? viewModel.visibleColumns.first?.name else { return }
        let gridRow = viewModel.gridRows[tableView.selectedRow]
        if viewModel.isEditingEnabled, gridRow.changeKind != .deletion {
            viewModel.focusInspector(rowID: gridRow.id, column: column)
        } else {
            presentQuickLook(rowID: gridRow.id, column: column)
        }
    }

    /// 中键点击单元格：选中并快速查看（`specs/02-workspace.md` §9）。
    func quickLook(row: Int, column: Int) {
        guard let tableView, row >= 0, row < viewModel.gridRows.count,
              column > 0, column < tableView.tableColumns.count else { return }
        let rowID = viewModel.gridRows[row].id
        let columnName = tableView.tableColumns[column].identifier.rawValue
        focusedColumnName = columnName
        isApplyingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelection = false
        pushSelection()
        presentQuickLook(rowID: rowID, column: columnName)
    }

    func copyDefault() {
        writeToPasteboard(viewModel.makeDefaultCopy().text)
    }

    func quickLookFocusedCell() {
        guard let rowID = currentFocusedRowID(),
              let column = focusedColumnName ?? viewModel.visibleColumns.first?.name else { return }
        presentQuickLook(rowID: rowID, column: column)
    }

    private func currentFocusedRowID() -> String? {
        if let tableView, tableView.selectedRow >= 0, tableView.selectedRow < viewModel.gridRows.count {
            return viewModel.gridRows[tableView.selectedRow].id
        }
        return viewModel.focusedRowID
    }

    private func presentQuickLook(rowID: String, column: String) {
        guard let initial = viewModel.quickLookContent(rowID: rowID, column: column) else { return }
        onQuickLook(initial)
        if initial.isLoading {
            Task { [weak self] in
                guard let self else { return }
                await self.viewModel.ensureFullValue(rowID: rowID, column: column)
                if let updated = self.viewModel.quickLookContent(rowID: rowID, column: column) {
                    self.onQuickLook(updated)
                }
            }
        }
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: 表头交互

    func headerClicked(columnIndex: Int, additive: Bool) {
        guard let tableView, columnIndex > 0, columnIndex < tableView.tableColumns.count else { return }
        let name = tableView.tableColumns[columnIndex].identifier.rawValue
        viewModel.toggleSort(column: name, additive: additive)
    }

    func makeColumnMenu(columnIndex: Int) -> NSMenu {
        let menu = NSMenu()
        if let tableView, columnIndex > 0, columnIndex < tableView.tableColumns.count {
            let name = tableView.tableColumns[columnIndex].identifier.rawValue
            let filterItem = NSMenuItem(
                title: "按此列筛选",
                action: #selector(menuFilterByColumn(_:)),
                keyEquivalent: ""
            )
            filterItem.target = self
            filterItem.representedObject = name
            menu.addItem(filterItem)
            menu.addItem(.separator())
        }
        let title = NSMenuItem(title: "显示 / 隐藏列", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for column in viewModel.columns {
            let item = NSMenuItem(title: column.name, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.name
            item.state = viewModel.hiddenColumns.contains(column.name) ? .off : .on
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuFilterByColumn(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        viewModel.applyQuickFilter(.byColumn(column: name))
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        viewModel.setColumnHidden(name, hidden: !viewModel.hiddenColumns.contains(name))
    }

    // MARK: 单元格右键菜单

    func makeCellMenu(row: Int, column: Int) -> NSMenu {
        contextRow = row
        contextColumn = column
        let menu = NSMenu()

        let quickLook = NSMenuItem(title: "快速查看", action: #selector(menuQuickLook(_:)), keyEquivalent: "")
        quickLook.target = self
        menu.addItem(quickLook)

        let copyRoot = NSMenuItem(title: "复制为", action: nil, keyEquivalent: "")
        let copyMenu = NSMenu()
        for format in CopyFormat.allCases {
            let item = NSMenuItem(title: format.displayName, action: #selector(menuCopy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format
            copyMenu.addItem(item)
        }
        copyRoot.submenu = copyMenu
        menu.addItem(copyRoot)
        menu.addItem(.separator())

        // T10：「按此值筛选 / 排除此值」。
        let filter = NSMenuItem(title: "按此值筛选", action: #selector(menuFilterByValue(_:)), keyEquivalent: "")
        filter.target = self
        filter.isEnabled = canFilterContextCell
        menu.addItem(filter)
        let exclude = NSMenuItem(title: "排除此值", action: #selector(menuExcludeValue(_:)), keyEquivalent: "")
        exclude.target = self
        exclude.isEnabled = canFilterContextCell
        menu.addItem(exclude)
        menu.addItem(.separator())

        let copyDDL = NSMenuItem(title: "复制表结构", action: #selector(menuCopyDDL(_:)), keyEquivalent: "")
        copyDDL.target = self
        copyDDL.isEnabled = viewModel.createStatement != nil
        menu.addItem(copyDDL)

        // T9：行操作菜单。
        let copyRow = NSMenuItem(title: "复制行", action: #selector(menuCopyRow(_:)), keyEquivalent: "")
        copyRow.target = self
        copyRow.isEnabled = viewModel.isEditingEnabled && canEditContextRow
        menu.addItem(copyRow)

        // `specs/08-import-export.md` §1：右键选中行 →「导出选中行…」。读操作，只读连接也可用。
        let exportRows = NSMenuItem(title: "导出选中行…", action: #selector(menuExportSelectedRows(_:)), keyEquivalent: "")
        exportRows.target = self
        exportRows.isEnabled = canExportSelectedRows
        menu.addItem(exportRows)

        let delete = NSMenuItem(title: "删除行", action: #selector(menuDeleteRow(_:)), keyEquivalent: "")
        delete.target = self
        delete.isEnabled = viewModel.isEditingEnabled && canEditContextRow
        menu.addItem(delete)

        let undo = NSMenuItem(title: "撤销该行的修改", action: #selector(menuUndoRow(_:)), keyEquivalent: "")
        undo.target = self
        undo.isEnabled = hasContextRowChange
        menu.addItem(undo)
        return menu
    }

    /// 上下文行是否可编辑（可定位、未标记删除）。
    private var canEditContextRow: Bool {
        guard contextRow >= 0, contextRow < viewModel.gridRows.count else { return false }
        let row = viewModel.gridRows[contextRow]
        return row.changeKind != .deletion && (row.locator != nil || viewModel.isInsertionRow(rowID: row.id))
    }

    /// 是否有可导出的选中行（需主键定位键）。
    private var canExportSelectedRows: Bool {
        let ids = selectedRowIDsForAction(fallbackRow: contextRow)
        guard !ids.isEmpty else { return false }
        let rows = viewModel.gridRows.filter { ids.contains($0.id) }
        return !rows.isEmpty && rows.allSatisfy { !($0.locator?.isEmpty ?? true) }
    }

    private var hasContextRowChange: Bool {
        guard contextRow >= 0, contextRow < viewModel.gridRows.count else { return false }
        return viewModel.rowChangeKind(rowID: viewModel.gridRows[contextRow].id) != nil
    }

    /// 上下文单元格是否可以拿来做值筛选。
    private var canFilterContextCell: Bool {
        guard let tableView, contextRow >= 0, contextRow < viewModel.gridRows.count,
              contextColumn > 0, contextColumn < tableView.tableColumns.count else { return false }
        return true
    }

    @objc private func menuFilterByValue(_ sender: NSMenuItem) {
        filterContextCell(exclude: false)
    }

    @objc private func menuExcludeValue(_ sender: NSMenuItem) {
        filterContextCell(exclude: true)
    }

    private func filterContextCell(exclude: Bool) {
        guard let tableView, contextRow >= 0, contextRow < viewModel.gridRows.count,
              contextColumn > 0, contextColumn < tableView.tableColumns.count else { return }
        viewModel.filterByCellValue(
            rowID: viewModel.gridRows[contextRow].id,
            column: tableView.tableColumns[contextColumn].identifier.rawValue,
            exclude: exclude
        )
    }

    /// 过滤面板打开时 `⌘I` 归面板（`specs/02-workspace.md` §9）。
    func addFilterCondition() {
        viewModel.addFilterCondition()
    }

    @objc private func menuCopyRow(_ sender: NSMenuItem) {
        let ids = selectedRowIDsForAction(fallbackRow: contextRow)
        Task { [weak self] in await self?.viewModel.copySelectedRows(rowIDs: ids) }
    }

    @objc private func menuDeleteRow(_ sender: NSMenuItem) {
        viewModel.deleteRows(rowIDs: selectedRowIDsForAction(fallbackRow: contextRow))
    }

    @objc private func menuExportSelectedRows(_ sender: NSMenuItem) {
        let ids = selectedRowIDsForAction(fallbackRow: contextRow)
        guard let source = viewModel.selectedRowsExportSource(rowIDs: ids) else { return }
        onExport?(source)
    }

    @objc private func menuUndoRow(_ sender: NSMenuItem) {
        guard contextRow >= 0, contextRow < viewModel.gridRows.count else { return }
        viewModel.undoRow(rowID: viewModel.gridRows[contextRow].id)
    }

    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        guard let tableView, contextRow >= 0, contextRow < viewModel.gridRows.count,
              contextColumn > 0, contextColumn < tableView.tableColumns.count else { return }
        presentQuickLook(
            rowID: viewModel.gridRows[contextRow].id,
            column: tableView.tableColumns[contextColumn].identifier.rawValue
        )
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? CopyFormat else { return }
        if format == .cellValue,
           let tableView,
           contextRow >= 0, contextRow < viewModel.gridRows.count,
           contextColumn > 0, contextColumn < tableView.tableColumns.count {
            let text = viewModel.makeCellCopy(
                rowID: viewModel.gridRows[contextRow].id,
                column: tableView.tableColumns[contextColumn].identifier.rawValue,
                format: format
            ).text
            writeToPasteboard(text)
            return
        }
        writeToPasteboard(viewModel.makeCopy(format: format).text)
    }

    @objc private func menuCopyDDL(_ sender: NSMenuItem) {
        guard let statement = viewModel.createStatement else { return }
        writeToPasteboard(statement)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let tableView, !isApplyingEstimatedWidth else { return }
        refreshColumnSeparators()
        // 只记「真的变了宽度」的那一列：拖一条分隔线只改一列，
        // 但通知里的 tableColumns 是所有列，照单全收会把整张表的列都标成「用户拖过」，
        // 自动适配从此再也碰不了它们（`07-data-grid.md` §4.2）。
        for column in tableView.tableColumns where column.identifier != Self.rowNumberIdentifier {
            let name = column.identifier.rawValue
            let stored = viewModel.columnWidths[name] ?? -1
            guard abs(stored - Double(column.width)) > 0.5 else { continue }
            viewModel.setColumnWidth(name, width: Double(column.width))
        }
        // 宽度变了 → x 映射变了，列窗口要重判。
        refreshColumnWindow()
    }
}

// MARK: - NSTableView 子类（右键与键盘）

/// 暴露右键菜单与网格内的按键行为（`Space` 快速查看、方向键移动焦点）。
final class DataGridTableView: NSTableView {

    weak var gridCoordinator: DataGridCoordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        if row >= 0, let menu = gridCoordinator?.makeCellMenu(row: row, column: column) {
            return menu
        }
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let characters = event.charactersIgnoringModifiers {
            switch characters.lowercased() {
            case "i":
                if gridCoordinator?.viewModel.isFilterVisible == true {
                    gridCoordinator?.addFilterCondition()
                } else {
                    gridCoordinator?.insertRow()
                }
                return
            case "d":
                gridCoordinator?.copySelectedRows()
                return
            default:
                break
            }
        }
        // ⌫ / ⌦：删除选中行（进暂存，`specs/04-data-editing.md` §6）。
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            gridCoordinator?.deleteSelectedRows()
            return
        }
        if event.charactersIgnoringModifiers == " ", flags.isEmpty {
            gridCoordinator?.quickLookFocusedCell()
            return
        }
        // ↩ / 小键盘 Enter：打开右侧字段栏并聚焦对应字段（等价于双击，`specs/02-workspace.md` §9）。
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            gridCoordinator?.activateFocusedCell()
            return
        }
        switch event.keyCode {
        case 123: // ←
            if flags.contains(.command) {
                gridCoordinator?.moveFocusToFirstColumn()
            } else {
                gridCoordinator?.moveFocusColumn(delta: -1)
            }
            return
        case 124: // →
            if flags.contains(.command) {
                gridCoordinator?.moveFocusToLastColumn()
            } else {
                gridCoordinator?.moveFocusColumn(delta: 1)
            }
            return
        case 125: // ↓
            if flags.contains(.command) {
                gridCoordinator?.moveFocusToLastRow()
                return
            }
        case 126: // ↑
            if flags.contains(.command) {
                gridCoordinator?.moveFocusToFirstRow()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// 中键点击 = 快速查看（`specs/02-workspace.md` §9）。
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let row = self.row(at: point)
            let column = self.column(at: point)
            gridCoordinator?.quickLook(row: row, column: column)
            return
        }
        super.otherMouseDown(with: event)
    }

    /// 左键点击：落在外键 `↗` 上时跳转，否则走表格默认的选中逻辑。
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        if let coordinator = gridCoordinator,
           coordinator.isForeignKeyArrowHit(row: row, column: column, point: point) {
            coordinator.openForeignKey(row: row, column: column)
            return
        }
        super.mouseDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        gridCoordinator?.copyDefault()
    }
}

// MARK: - 行与表头子类

/// 只负责「新增 / 修改 / 删除」这种整行特例底色；隔行底色与网格线交给 `GridCanvasView`
/// 一次画完（`docs/tech-designs/07-data-grid.md` §4.1）。
final class TableRowView: NSTableRowView {

    /// 整行特例底色；`nil` 表示这一行不额外铺色（隔行底色画在下面一层）。
    var fillColor: NSColor?

    override func drawBackground(in dirtyRect: NSRect) {
        guard let fillColor else { return }
        fillColor.setFill()
        dirtyRect.fill()
    }
}

final class GridHeaderView: NSTableHeaderView {

    weak var coordinator: DataGridCoordinator?

    override func draw(_ dirtyRect: NSRect) {
        AppNSColor.gridHeader.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isOnDivider(point) {
            let columnIndex = column(at: point)
            if columnIndex > 0 {
                coordinator?.headerClicked(
                    columnIndex: columnIndex,
                    additive: event.modifierFlags.contains(.shift)
                )
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = column(at: point)
        return coordinator?.makeColumnMenu(columnIndex: index)
    }

    private func isOnDivider(_ point: NSPoint) -> Bool {
        let count = tableView?.numberOfColumns ?? 0
        for index in 0..<count {
            let rect = headerRect(ofColumn: index)
            if abs(point.x - rect.maxX) < 5 { return true }
        }
        return false
    }
}

// MARK: - 单元格视图

/// 网格单元格：只读文本 + 可选的只读三态复选框。
///
/// T9 会在这里加入「已修改 / 新增 / 删除」的底色与角标；
/// 但**编辑永远不在网格里发生**（S14）。
final class GridCellView: NSTableCellView {

    private let valueLabel = NSTextField(labelWithString: "")
    private var checkboxButton: NSButton?
    /// 已修改单元格左上角的小三角（`docs/tech-designs/07-data-grid.md` §4）。
    private let editMarker = NSImageView()
    /// 外键列尾部固定的 `↗`（`specs/03-data-browsing.md` §10）。
    private let foreignKeyArrow = NSTextField(labelWithString: "↗")
    private var foreignKeyWidthConstraint: NSLayoutConstraint!
    /// 最近一次配置的行状态；外观切换时按新外观重算底色（`06-ui-layer.md` §9）。
    private var changeKind: GridRowChangeKind?
    private var isEdited = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.cell?.truncatesLastVisibleLine = true
        valueLabel.isEditable = false
        valueLabel.isSelectable = false
        valueLabel.isBordered = false
        valueLabel.drawsBackground = false
        valueLabel.maximumNumberOfLines = 1
        addSubview(valueLabel)

        foreignKeyArrow.translatesAutoresizingMaskIntoConstraints = false
        foreignKeyArrow.textColor = .controlAccentColor
        foreignKeyArrow.isEditable = false
        foreignKeyArrow.isSelectable = false
        foreignKeyArrow.isBordered = false
        foreignKeyArrow.drawsBackground = false
        foreignKeyArrow.isHidden = true
        addSubview(foreignKeyArrow)
        foreignKeyWidthConstraint = foreignKeyArrow.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            // 值末尾让位给尾部的 `↗`；箭头隐藏时其宽度为 0，值自然占满。
            valueLabel.trailingAnchor.constraint(equalTo: foreignKeyArrow.leadingAnchor, constant: -3),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            foreignKeyArrow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            foreignKeyArrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            foreignKeyWidthConstraint,
        ])

        checkboxButton?.isHidden = true

        editMarker.image = NSImage(
            systemSymbolName: "arrowtriangle.up.left.fill",
            accessibilityDescription: "已修改"
        )
        editMarker.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .semibold)
        editMarker.contentTintColor = .systemOrange
        editMarker.translatesAutoresizingMaskIntoConstraints = false
        editMarker.isHidden = true
        addSubview(editMarker)
        NSLayoutConstraint.activate([
            editMarker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            editMarker.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ])
    }

    func configure(
        display: CellDisplay,
        font: NSFont,
        isSelected: Bool,
        changeKind: GridRowChangeKind? = nil,
        isEdited: Bool = false,
        isForeignKey: Bool = false
    ) {
        if toolTip != display.tooltip { toolTip = display.tooltip }
        applyEditingBackground(changeKind: changeKind, isEdited: isEdited)

        if let state = display.checkbox {
            valueLabel.isHidden = true
            let button = checkboxButton ?? makeCheckbox()
            button.isHidden = false
            setForeignKeyArrow(false, font: font)
            switch state {
            case .off: button.state = .off
            case .on: button.state = .on
            case .mixed: button.state = .mixed
            }
            return
        }

        checkboxButton?.isHidden = true
        valueLabel.isHidden = false
        valueLabel.alignment = alignment(for: display.alignment)

        // 外键列在本行非 NULL 时追加 `↗`；固定在最右侧，与 `isForeignKeyArrowHit` 的命中区对齐。
        setForeignKeyArrow(isForeignKey && !display.isNull, font: font)

        // 已删除的行整行加删除线并变淡（`specs/03-data-browsing.md` §4）。
        if changeKind == .deletion {
            let attributes: [NSAttributedString.Key: Any] = [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: font,
            ]
            valueLabel.attributedStringValue = NSAttributedString(string: display.text, attributes: attributes)
        } else if display.isNull {
            valueLabel.stringValue = display.text
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        } else {
            valueLabel.stringValue = display.text
            valueLabel.textColor = .labelColor
            valueLabel.font = font
        }
        _ = isSelected
    }

    /// 惰性创建复选框：纯文本列永远不需要它。
    /// 关键在于**不要**在每个单元格 init 时就 new 一个 NSButton —— 它会让每次
    /// Auto Layout 都进 `NSButton.intrinsicContentSize`（实测会拖进 SwiftUI 的
    /// AttributeGraph），开销随可见单元格数线性放大。
    private func makeCheckbox() -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = false
        button.allowsMixedState = true
        button.controlSize = .small
        button.title = ""
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        checkboxButton = button
        return button
    }

    /// 显示 / 隐藏尾部的 `↗`；隐藏时宽度归 0，不占值文本的空间。
    private func setForeignKeyArrow(_ visible: Bool, font: NSFont) {
        foreignKeyArrow.isHidden = !visible
        foreignKeyWidthConstraint.constant = visible ? 13 : 0
        foreignKeyArrow.font = font
    }

    /// 当前渲染的文本（不含尾部的 `↗`）；供单测断言。
    var renderedText: String { valueLabel.attributedStringValue.string }

    /// 外键 `↗` 是否可见；供单测断言。
    var isForeignKeyIndicatorVisible: Bool { !foreignKeyArrow.isHidden }

    /// 已修改单元格橙色底 + 左上角小三角（`specs/04-data-editing.md` §3、`07-data-grid.md` §4）。
    private func applyEditingBackground(changeKind: GridRowChangeKind?, isEdited: Bool) {
        self.changeKind = changeKind
        self.isEdited = isEdited
        wantsLayer = true
        let isModified = changeKind == .update && isEdited
        switch changeKind {
        case .insertion:
            layer?.backgroundColor = NSColor.systemGreen.withDynamicAlpha(0.10).cgColor
        case .deletion:
            layer?.backgroundColor = NSColor.clear.cgColor
        case .update where isEdited:
            layer?.backgroundColor = NSColor.systemOrange.withDynamicAlpha(0.22).cgColor
        default:
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        editMarker.isHidden = !isModified
    }

    /// `cgColor` 是快照，不会随外观自动更新（`06-ui-layer.md` §9），外观变了要重算。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyEditingBackground(changeKind: changeKind, isEdited: isEdited)
    }

    private func alignment(for alignment: CellAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .trailing: return .right
        case .center: return .center
        }
    }
}
