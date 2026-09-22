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

    func makeCoordinator() -> DataGridCoordinator {
        DataGridCoordinator(viewModel: viewModel, preferences: preferences, onQuickLook: onQuickLook)
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
        tableView.usesAlternatingRowBackgroundColors = preferences.alternateRowColors
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.rowHeight = coordinator.rowHeight
        tableView.target = coordinator
        tableView.action = #selector(DataGridCoordinator.tableViewClicked(_:))
        tableView.doubleAction = #selector(DataGridCoordinator.tableViewDoubleClicked(_:))
        tableView.setAccessibilityLabel("表数据网格")

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
        scrollView.backgroundColor = .textBackgroundColor

        coordinator.rebuildColumns()
        coordinator.reloadAll()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.onQuickLook = onQuickLook
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
    weak var tableView: DataGridTableView?

    private var lastDataRevision = -1
    private var lastFontSize = -1
    private var lastColumnSignature = ""
    private var didEstimateWidths = false
    private var isApplyingSelection = false
    /// 当前焦点列（网格自己维护；键盘 ← → 与点击都会更新）。
    private var focusedColumnName: String?
    private var contextRow: Int = -1
    private var contextColumn: Int = -1

    init(viewModel: TableDataViewModel, preferences: Preferences, onQuickLook: @escaping (QuickLookContent) -> Void) {
        self.viewModel = viewModel
        self.preferences = preferences
        self.onQuickLook = onQuickLook
        self.focusedColumnName = viewModel.focusedColumn ?? viewModel.visibleColumns.first?.name
        super.init()
    }

    // MARK: 字体

    var cellFont: NSFont {
        NSFont.systemFont(ofSize: CGFloat(preferences.gridFontSize))
    }

    var rowHeight: CGFloat {
        max(20, CGFloat(preferences.gridFontSize) + 9)
    }

    // MARK: 同步

    func sync() {
        guard let tableView else { return }
        tableView.enclosingScrollView?.autohidesScrollers = preferences.autoHideScrollers
        tableView.usesAlternatingRowBackgroundColors = preferences.alternateRowColors

        if lastFontSize != preferences.gridFontSize {
            lastFontSize = preferences.gridFontSize
            tableView.rowHeight = rowHeight
            tableView.reloadData()
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
            tableView.reloadData()
            applyEstimatedWidthsIfNeeded()
        }

        applySelectionFromViewModel()
    }

    func reloadAll() {
        lastDataRevision = viewModel.dataRevision
        tableView?.reloadData()
        applyEstimatedWidthsIfNeeded()
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
    }

    private func headerTitle(for column: ColumnInfo, baseFont: NSFont) -> NSAttributedString {
        var text = column.name
        if column.isPrimaryKey { text = "🔑 " + text }
        if let index = viewModel.sortOrders.firstIndex(where: { $0.column == column.name }) {
            let direction = viewModel.sortOrders[index].direction
            let marker = viewModel.sortOrders.count > 1 ? "\(direction.arrow)\(index + 1)" : direction.arrow
            text += " \(marker)"
        }
        let font: NSFont = column.isPrimaryKey
            ? NSFont.boldSystemFont(ofSize: baseFont.pointSize)
            : baseFont
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    private func fallbackWidth(for column: ColumnInfo) -> CGFloat {
        let headerWidth = CGFloat((column.name.count + (column.isPrimaryKey ? 3 : 1)) * 9 + 26)
        return min(max(headerWidth, 60), 400)
    }

    /// 首次拿到数据后按内容估算列宽（上限 400pt），用户拖过的列不覆盖。
    private func applyEstimatedWidthsIfNeeded() {
        guard !didEstimateWidths, !viewModel.rows.isEmpty, let tableView else { return }
        didEstimateWidths = true
        let context = viewModel.cellDisplayContext
        for tableColumn in tableView.tableColumns where tableColumn.identifier != Self.rowNumberIdentifier {
            let name = tableColumn.identifier.rawValue
            guard viewModel.columnWidths[name] == nil,
                  let column = viewModel.visibleColumns.first(where: { $0.name == name }) else { continue }
            var sample = column.name.count
            for row in viewModel.rows.prefix(50) {
                guard let cell = row.cells[name] else { continue }
                let display = CellDisplayFormatter.display(
                    value: cell.displayValue,
                    isTruncated: cell.isTruncated && cell.fullValue == nil,
                    totalByteCount: cell.totalByteCount,
                    column: column,
                    context: context
                )
                sample = max(sample, display.text.count)
            }
            let width = min(max(CGFloat(sample) * 8 + 24, fallbackWidth(for: column)), 400)
            tableColumn.width = width
            viewModel.setColumnWidth(name, width: Double(width))
        }
    }

    // MARK: 数据源

    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row >= 0, row < viewModel.rows.count else { return nil }
        let gridRow = viewModel.rows[row]
        let isSelected = tableView.selectedRowIndexes.contains(row)

        if tableColumn.identifier == Self.rowNumberIdentifier {
            let cell = rowNumberCell(tableView)
            let number = viewModel.pageState.offset + row + 1
            cell.textField?.stringValue = gridRow.changeKind?.marker ?? String(number)
            return cell
        }

        guard let column = viewModel.columns.first(where: { $0.name == tableColumn.identifier.rawValue }),
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
        cell.configure(display: display, font: cellFont, isSelected: isSelected)
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
        guard row >= 0, row < viewModel.rows.count,
              column > 0, column < sender.tableColumns.count else { return }
        presentQuickLook(rowID: viewModel.rows[row].id, column: sender.tableColumns[column].identifier.rawValue)
    }

    private func pushSelection() {
        guard let tableView else { return }
        let ids = tableView.selectedRowIndexes.compactMap { index -> String? in
            guard index >= 0, index < viewModel.rows.count else { return nil }
            return viewModel.rows[index].id
        }
        let focusedIndex = tableView.selectedRow
        let focusedID = (focusedIndex >= 0 && focusedIndex < viewModel.rows.count)
            ? viewModel.rows[focusedIndex].id
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
        let indexes = IndexSet(viewModel.rows.enumerated().compactMap { index, row in
            targetIDs.contains(row.id) ? index : nil
        })
        if tableView.selectedRowIndexes != indexes {
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }
        if let focusedRowID = viewModel.focusedRowID,
           let index = viewModel.rows.firstIndex(where: { $0.id == focusedRowID }) {
            focusedColumnName = viewModel.focusedColumn ?? focusedColumnName
            if tableView.selectedRow != index {
                isApplyingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true)
                isApplyingSelection = false
            }
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

    func copyDefault() {
        writeToPasteboard(viewModel.makeDefaultCopy().text)
    }

    func quickLookFocusedCell() {
        guard let rowID = currentFocusedRowID(),
              let column = focusedColumnName ?? viewModel.visibleColumns.first?.name else { return }
        presentQuickLook(rowID: rowID, column: column)
    }

    private func currentFocusedRowID() -> String? {
        if let tableView, tableView.selectedRow >= 0, tableView.selectedRow < viewModel.rows.count {
            return viewModel.rows[tableView.selectedRow].id
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

    func makeColumnMenu() -> NSMenu {
        let menu = NSMenu()
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
        let filter = NSMenuItem(title: "按此值筛选", action: nil, keyEquivalent: "")
        filter.isEnabled = false
        menu.addItem(filter)
        let exclude = NSMenuItem(title: "排除此值", action: nil, keyEquivalent: "")
        exclude.isEnabled = false
        menu.addItem(exclude)
        menu.addItem(.separator())

        let copyDDL = NSMenuItem(title: "复制表结构", action: #selector(menuCopyDDL(_:)), keyEquivalent: "")
        copyDDL.target = self
        copyDDL.isEnabled = viewModel.createStatement != nil
        menu.addItem(copyDDL)

        // T9：「删除行」。
        let delete = NSMenuItem(title: "删除行", action: nil, keyEquivalent: "")
        delete.isEnabled = false
        menu.addItem(delete)
        return menu
    }

    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        guard let tableView, contextRow >= 0, contextRow < viewModel.rows.count,
              contextColumn > 0, contextColumn < tableView.tableColumns.count else { return }
        presentQuickLook(
            rowID: viewModel.rows[contextRow].id,
            column: tableView.tableColumns[contextColumn].identifier.rawValue
        )
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? CopyFormat else { return }
        if format == .cellValue,
           let tableView,
           contextRow >= 0, contextRow < viewModel.rows.count,
           contextColumn > 0, contextColumn < tableView.tableColumns.count {
            let text = viewModel.makeCellCopy(
                rowID: viewModel.rows[contextRow].id,
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
        guard let tableView else { return }
        for column in tableView.tableColumns where column.identifier != Self.rowNumberIdentifier {
            viewModel.setColumnWidth(column.identifier.rawValue, width: Double(column.width))
        }
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
        if event.charactersIgnoringModifiers == " ", flags.isEmpty {
            gridCoordinator?.quickLookFocusedCell()
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
        default:
            break
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        gridCoordinator?.copyDefault()
    }
}

// MARK: - 表头子类（点击排序 + 右键列菜单）

final class GridHeaderView: NSTableHeaderView {

    weak var coordinator: DataGridCoordinator?

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
        coordinator?.makeColumnMenu()
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
    private let checkboxButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)

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
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        checkboxButton.translatesAutoresizingMaskIntoConstraints = false
        checkboxButton.isEnabled = false
        checkboxButton.allowsMixedState = true
        checkboxButton.controlSize = .small
        checkboxButton.title = ""
        addSubview(checkboxButton)
        NSLayoutConstraint.activate([
            checkboxButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkboxButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        checkboxButton.isHidden = true
    }

    func configure(display: CellDisplay, font: NSFont, isSelected: Bool) {
        toolTip = display.tooltip

        if let state = display.checkbox {
            valueLabel.isHidden = true
            checkboxButton.isHidden = false
            switch state {
            case .off: checkboxButton.state = .off
            case .on: checkboxButton.state = .on
            case .mixed: checkboxButton.state = .mixed
            }
            return
        }

        checkboxButton.isHidden = true
        valueLabel.isHidden = false
        valueLabel.stringValue = display.text
        valueLabel.alignment = alignment(for: display.alignment)

        if display.isNull {
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        } else {
            valueLabel.textColor = .labelColor
            valueLabel.font = font
        }
        _ = isSelected
    }

    private func alignment(for alignment: CellAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .trailing: return .right
        case .center: return .center
        }
    }
}
