import SwiftUI
import AppKit

/// 查询结果网格：只读，复用表数据网格的**单元格渲染**（`GridCellView` + `CellDisplayFormatter`）。
///
/// 决策：`DataGridView` 与 `TableDataViewModel`（显示条数 / 暂存 / 字段栏 / 行定位）强绑定，
/// 结果集没有行定位键也不需要编辑（S16），因此不复用整个 `DataGridView`，
/// 而是复用其单元格渲染与 `CellDisplayFormatter` 这一「展示规则的唯一实现」，
/// 另写一层更轻的 `NSTableView` 桥接。见交付报告。
struct QueryResultGridView: NSViewRepresentable {

    let columns: [ColumnInfo]
    let rows: [[SQLValue]]
    let displayContext: CellDisplayContext
    let fontSize: Double
    let alternateRowColors: Bool
    var onQuickLook: (QuickLookContent) -> Void
    /// 结果网格右键「导出结果…」入口（`specs/08-import-export.md` §1）。
    var onExport: (() -> Void)?

    func makeCoordinator() -> QueryResultGridCoordinator {
        QueryResultGridCoordinator(
            columns: columns,
            rows: rows,
            displayContext: displayContext,
            fontSize: fontSize,
            alternateRowColors: alternateRowColors,
            onQuickLook: onQuickLook,
            onExport: onExport
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = QueryResultTableView()
        tableView.gridCoordinator = coordinator
        coordinator.tableView = tableView
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = alternateRowColors
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.rowHeight = coordinator.rowHeight
        tableView.target = coordinator
        tableView.doubleAction = #selector(QueryResultGridCoordinator.tableViewDoubleClicked(_:))
        tableView.setAccessibilityLabel("查询结果网格")

        let headerView = ResultGridHeaderView()
        headerView.coordinator = coordinator
        tableView.headerView = headerView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        coordinator.rebuildColumns()
        coordinator.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onQuickLook = onQuickLook
        context.coordinator.onExport = onExport
        context.coordinator.sync()
    }
}

// MARK: - 协调器

@MainActor
final class QueryResultGridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    static let rowNumberIdentifier = NSUserInterfaceItemIdentifier("__mtl_result_row_number__")

    var columns: [ColumnInfo]
    var rows: [[SQLValue]]
    var displayContext: CellDisplayContext
    var fontSize: Double
    var alternateRowColors: Bool
    var onQuickLook: (QuickLookContent) -> Void
    var onExport: (() -> Void)?
    weak var tableView: QueryResultTableView?

    /// 本地排序（不重新查询，`specs/06-query-editor.md` §4）。
    private var sortColumn: String?
    private var sortAscending = true
    private var order: [Int] = []
    /// 被隐藏的结果列下标（列显隐，`specs/06-query-editor.md` §4）。按列下标跟踪以允许重名列。
    private(set) var hiddenColumnIndexes: Set<Int> = []

    init(
        columns: [ColumnInfo],
        rows: [[SQLValue]],
        displayContext: CellDisplayContext,
        fontSize: Double,
        alternateRowColors: Bool,
        onQuickLook: @escaping (QuickLookContent) -> Void,
        onExport: (() -> Void)? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.displayContext = displayContext
        self.fontSize = fontSize
        self.alternateRowColors = alternateRowColors
        self.onQuickLook = onQuickLook
        self.onExport = onExport
        self.order = Array(rows.indices)
        super.init()
    }

    var cellFont: NSFont {
        NSFont.systemFont(ofSize: CGFloat(fontSize))
    }

    var rowHeight: CGFloat {
        max(20, CGFloat(fontSize) + 9)
    }

    func sync() {
        guard let tableView else { return }
        tableView.usesAlternatingRowBackgroundColors = alternateRowColors
        if abs(tableView.rowHeight - rowHeight) > 0.5 {
            tableView.rowHeight = rowHeight
            tableView.reloadData()
        }
    }

    func reloadData() {
        order = Array(rows.indices)
        applySort()
        tableView?.reloadData()
    }

    // MARK: 列

    func rebuildColumns() {
        guard let tableView else { return }
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        hiddenColumnIndexes = hiddenColumnIndexes.filter { $0 >= 0 && $0 < columns.count }
        let rowColumn = NSTableColumn(identifier: Self.rowNumberIdentifier)
        rowColumn.title = "#"
        rowColumn.width = 48
        rowColumn.minWidth = 36
        rowColumn.maxWidth = 80
        rowColumn.resizingMask = []
        rowColumn.isEditable = false
        tableView.addTableColumn(rowColumn)

        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.headerCell.attributedStringValue = NSAttributedString(string: column.name)
            tableColumn.headerToolTip = "\(column.fieldType)"
            tableColumn.width = estimatedWidth(for: column)
            tableColumn.minWidth = 40
            tableColumn.maxWidth = 2000
            tableColumn.resizingMask = .userResizingMask
            tableColumn.isEditable = false
            tableView.addTableColumn(tableColumn)
        }
        applyColumnVisibility()
    }

    /// 把 `hiddenColumnIndexes` 应用到 `NSTableView`（行号列永远可见）。
    private func applyColumnVisibility() {
        guard let tableView else { return }
        for (index, tableColumn) in tableView.tableColumns.enumerated() where index > 0 {
            tableColumn.isHidden = hiddenColumnIndexes.contains(index - 1)
        }
    }

    private func estimatedWidth(for column: ColumnInfo) -> CGFloat {
        let index = columns.firstIndex(of: column) ?? 0
        var sample = column.name.count
        for rowIndex in order.prefix(50) where rowIndex < rows.count && index < rows[rowIndex].count {
            let value = rows[rowIndex][index]
            sample = max(sample, min(displayText(value, column: column).count, 40))
        }
        return min(max(CGFloat(sample) * 8 + 24, 70), 400)
    }

    // MARK: 数据源

    func numberOfRows(in tableView: NSTableView) -> Int {
        order.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, order.indices.contains(row) else { return nil }
        let sourceIndex = order[row]
        guard rows.indices.contains(sourceIndex) else { return nil }

        if tableColumn.identifier == Self.rowNumberIdentifier {
            let cell = rowNumberCell(tableView)
            cell.textField?.stringValue = String(sourceIndex + 1)
            return cell
        }

        guard let columnIndex = Int(tableColumn.identifier.rawValue),
              columns.indices.contains(columnIndex),
              rows[sourceIndex].indices.contains(columnIndex) else { return nil }
        let column = columns[columnIndex]
        let display = CellDisplayFormatter.display(
            value: rows[sourceIndex][columnIndex],
            column: column,
            context: displayContext
        )
        let cell = cellView(tableView, identifier: tableColumn.identifier)
        cell.configure(display: display, font: cellFont, isSelected: tableView.selectedRowIndexes.contains(row))
        return cell
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

    // MARK: 排序（本地）

    func headerClicked(tableColumn: NSTableColumn) {
        guard let index = Int(tableColumn.identifier.rawValue), columns.indices.contains(index) else { return }
        let name = columns[index].name
        if sortColumn == name {
            if sortAscending {
                sortAscending = false
            } else {
                sortColumn = nil
                sortAscending = true
            }
        } else {
            sortColumn = name
            sortAscending = true
        }
        applySort()
        tableView?.reloadData()
        updateHeaderTitles()
    }

    private func applySort() {
        guard let sortColumn, let index = columns.firstIndex(where: { $0.name == sortColumn }) else {
            order = Array(rows.indices)
            return
        }
        order = rows.indices.sorted { lhs, rhs in
            let left = displayText(value(at: lhs, column: index), column: columns[index])
            let right = displayText(value(at: rhs, column: index), column: columns[index])
            let result = left.localizedStandardCompare(right)
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func value(at row: Int, column: Int) -> SQLValue {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return .null }
        return rows[row][column]
    }

    private func displayText(_ value: SQLValue, column: ColumnInfo) -> String {
        CellDisplayFormatter.display(value: value, column: column, context: displayContext).text
    }

    func updateHeaderTitles() {
        guard let tableView else { return }
        for tableColumn in tableView.tableColumns where tableColumn.identifier != Self.rowNumberIdentifier {
            guard let index = Int(tableColumn.identifier.rawValue), columns.indices.contains(index) else { continue }
            var title = columns[index].name
            if sortColumn == columns[index].name {
                title += sortAscending ? " ↑" : " ↓"
            }
            tableColumn.headerCell.attributedStringValue = NSAttributedString(string: title)
        }
    }

    // MARK: 交互

    func tableViewColumnDidResize(_ notification: Notification) {
        // 结果集是临时的，不记忆列宽（S16 / 结果集无持久化）。
    }

    @objc func tableViewDoubleClicked(_ sender: NSTableView) {
        presentQuickLook(row: sender.clickedRow, column: sender.clickedColumn)
    }

    func quickLookFocusedCell() {
        guard let tableView, tableView.selectedRow >= 0 else { return }
        presentQuickLook(row: tableView.selectedRow, column: max(1, tableView.selectedColumn))
    }

    func copySelection() {
        guard let tableView else { return }
        let indexes = tableView.selectedRowIndexes.sorted()
        guard !indexes.isEmpty else { return }
        let selectedRows = indexes.compactMap { order.indices.contains($0) ? rows[order[$0]] : nil }
        let text = CopyFormatter.format(
            rows: selectedRows,
            columns: columns,
            format: .csvWithHeader
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func makeCellMenu(row: Int, column: Int) -> NSMenu {
        let menu = NSMenu()
        let quickLook = NSMenuItem(title: "快速查看", action: #selector(menuQuickLook(_:)), keyEquivalent: "")
        quickLook.target = self
        menu.addItem(quickLook)
        let copy = NSMenuItem(title: "复制为 CSV（含表头）", action: #selector(menuCopy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        // `specs/08-import-export.md` §1 / `specs/06-query-editor.md` §4：结果集导出。
        let export = NSMenuItem(title: "导出结果…", action: #selector(menuExport(_:)), keyEquivalent: "")
        export.target = self
        export.isEnabled = onExport != nil
        menu.addItem(export)
        return menu
    }

    /// 结果网格表头右键菜单：`显示 / 隐藏列`（与表数据网格 `DataGridView.makeColumnMenu` 交互一致）。
    func makeHeaderMenu(columnIndex: Int) -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "显示 / 隐藏列", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        for (index, column) in columns.enumerated() {
            let item = NSMenuItem(title: column.name, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = hiddenColumnIndexes.contains(index) ? .off : .on
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, columns.indices.contains(index) else { return }
        hiddenColumnIndexes = ResultColumnVisibility.toggling(
            index: index,
            in: hiddenColumnIndexes,
            columnCount: columns.count
        )
        applyColumnVisibility()
    }

    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        guard let tableView else { return }
        presentQuickLook(row: tableView.clickedRow, column: tableView.clickedColumn)
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        copySelection()
    }

    @objc private func menuExport(_ sender: NSMenuItem) {
        onExport?()
    }

    private func presentQuickLook(row: Int, column: Int) {
        guard order.indices.contains(row) else { return }
        let sourceIndex = order[row]
        guard column > 0, columns.indices.contains(column - 1) else { return }
        let columnIndex = column - 1
        let columnInfo = columns[columnIndex]
        let value = value(at: sourceIndex, column: columnIndex)
        onQuickLook(makeQuickLookContent(column: columnInfo, value: value))
    }

    private func makeQuickLookContent(column: ColumnInfo, value: SQLValue) -> QuickLookContent {
        let kind = CellDisplayFormatter.quickLookKind(for: column, value: value)
        switch value {
        case .null:
            return QuickLookContent(
                title: "快速查看 · \(column.name)",
                columnName: column.name,
                kind: kind,
                text: displayContext.nullText,
                isNull: true
            )
        case .binary(let data):
            return QuickLookContent(
                title: "快速查看 · \(column.name)",
                columnName: column.name,
                kind: kind,
                data: data,
                byteCount: data.count
            )
        default:
            return QuickLookContent(
                title: "快速查看 · \(column.name)",
                columnName: column.name,
                kind: kind,
                text: value.textValue ?? ""
            )
        }
    }
}

// MARK: - 子类

final class QueryResultTableView: NSTableView {

    weak var gridCoordinator: QueryResultGridCoordinator?

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
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            gridCoordinator?.copySelection()
            return
        }
        if event.charactersIgnoringModifiers == " ", flags.isEmpty {
            gridCoordinator?.quickLookFocusedCell()
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        gridCoordinator?.copySelection()
    }
}

final class ResultGridHeaderView: NSTableHeaderView {

    weak var coordinator: QueryResultGridCoordinator?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isOnDivider(point) {
            let columnIndex = column(at: point)
            if columnIndex > 0, let tableView,
               tableView.tableColumns.indices.contains(columnIndex) {
                coordinator?.headerClicked(tableColumn: tableView.tableColumns[columnIndex])
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return coordinator?.makeHeaderMenu(columnIndex: column(at: point))
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
