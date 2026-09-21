import AppKit
import Foundation
import os

// MARK: - 数据网格（AppKit 侧）
//
// `NSTableView`（view-based）的数据源 / 委托与增量刷新都收敛在这里。
// SwiftUI 只通过 `DataGridView`（NSViewRepresentable）声明参数与回调，
// 状态由 `TableDataViewModel` 唯一持有。见 docs/tech-designs/06-ui-layer.md §4、§6。
//
// 增量刷新（硬约束）：
// - 列集合 / 行集合（身份序列）变化 → 全量 `reloadData`（页码 / 排序 / 过滤）；
// - 单字段编辑 / 整行状态变化 / 焦点变化 → 只重载受影响的行。
//
// 网格只读：单元格不承载编辑器，双击可编辑表会请求展开右侧字段栏。

/// 复制命令的种类（右键「复制为」菜单用）。
enum GridCopyKind: String, CaseIterable, Sendable {
    case cell
    case row
    case selectedRows
    case column
    case columnNames
    case json
    case markdown
    case csv
    case csvWithHeader
    case sqlInsert
    case createStatement

    var title: String {
        switch self {
        case .cell: return "复制单元格值"
        case .row: return "复制行"
        case .selectedRows: return "复制选中行"
        case .column: return "复制整列的值"
        case .columnNames: return "复制列名"
        case .json: return "复制为 JSON"
        case .markdown: return "复制为 Markdown 表格"
        case .csv: return "复制为 CSV"
        case .csvWithHeader: return "复制为 CSV（含表头）"
        case .sqlInsert: return "复制为 SQL INSERT"
        case .createStatement: return "复制表结构"
        }
    }
}

/// 一列在网格里的渲染规格。
struct GridColumnSpec: Hashable, Sendable {
    var name: String
    var kind: ColumnKind
    var isPrimaryKey: Bool
    var isForeignKey: Bool
    var rawTypeText: String
    var isNullable: Bool
    var dataType: String

    /// 列头 tooltip：`` `name` LONGTYPE NULL ``。
    var headerToolTip: String {
        let nullable = isNullable ? "NULL" : "NOT NULL"
        return "`\(name)` \(rawTypeText.uppercased()) \(nullable)"
    }
}

/// 网格外观（来自偏好；变化时全量重绘）。
struct GridAppearance: Equatable {
    var nullText: String = "NULL"
    var fontSize: Double = 13
    var alternatingRows: Bool = true
}

// MARK: - NSTableView 子类

/// 纯交互：把点击 / 按键 / 右键 / 中键转成对 `DataGridController` 的调用。
final class DataGridTableView: NSTableView {
    weak var interactionDelegate: DataGridController?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitRow = row(at: point)
        if hitRow >= 0, hitRow == interactionDelegate?.insertRowIndex {
            interactionDelegate?.handleInsertRowClick()
            return
        }
        super.mouseDown(with: event)
        interactionDelegate?.handleCellClick(row: hitRow, column: column(at: point))
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            let point = convert(event.locationInWindow, from: nil)
            interactionDelegate?.handleQuickLook(row: row(at: point), column: column(at: point))
            return
        }
        super.otherMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        interactionDelegate?.prepareContextMenu(row: row(at: point), column: column(at: point))
        return interactionDelegate?.makeContextMenu()
    }

    override func keyDown(with event: NSEvent) {
        if interactionDelegate?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }
}

/// 表头：右键列头提供「按此列筛选」。
final class DataGridHeaderView: NSTableHeaderView {
    weak var interactionDelegate: DataGridController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        interactionDelegate?.prepareHeaderContextMenu(column: column(at: point))
        return interactionDelegate?.makeHeaderContextMenu()
    }
}

// MARK: - 单元格视图

/// 只读单元格：文字 + 状态底色 + 焦点边框。
final class GridCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    var stateColor: NSColor? {
        didSet { needsDisplay = true }
    }
    var isSelectedRow = false {
        didSet { needsDisplay = true }
    }
    var isFocusedCell = false {
        didSet { needsDisplay = true }
    }
    var isInsertPlaceholder = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(attributed: NSAttributedString,
                   stateColor: NSColor?,
                   isSelected: Bool,
                   isFocused: Bool,
                   isPlaceholder: Bool) {
        label.attributedStringValue = attributed
        self.stateColor = stateColor
        self.isSelectedRow = isSelected
        self.isFocusedCell = isFocused
        self.isInsertPlaceholder = isPlaceholder
    }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor?
        if isInsertPlaceholder {
            background = NSColor.systemGreen.withAlphaComponent(0.08)
        } else if let stateColor {
            background = stateColor
        } else if isSelectedRow {
            background = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22)
        } else {
            background = nil
        }
        if let background {
            background.setFill()
            bounds.fill()
        }
        if isFocusedCell {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 2
            path.stroke()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - Controller

/// `NSTableViewDataSource` / `NSTableViewDelegate`，同时负责把表格状态与 ViewModel 对齐。
@MainActor
final class DataGridController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    weak var tableView: DataGridTableView?
    private weak var model: TableDataViewModel?
    private let preferences: PreferencesStore
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    // MARK: 回调（跨到 SwiftUI 边界）

    var onQuickLook: ((RowIdentity, String) -> Void)?
    var onBeginEdit: ((RowIdentity, String) -> Void)?
    var onForeignKeyJump: ((RowIdentity, String, CellValue) -> Void)?
    var onToast: ((String) -> Void)?
    var onFilterByValue: ((String, CellValue, Bool) -> Void)?
    /// 右键列头 → 按此列筛选。
    var onFilterByColumn: ((String) -> Void)?
    var onExportSelected: ((Set<RowIdentity>) -> Void)?
    var onRequestPreview: (() -> Void)?
    var onRequestCommit: (() -> Void)?
    var onRequestDiscard: (() -> Void)?
    /// 生成 SQL 字面量需要连接的转义闭包（`MySQLSession.literalizer()`）。
    var literalizerProvider: (() async -> SQLValueLiteralizer)?

    // MARK: 状态

    private var specs: [GridColumnSpec] = []
    /// specs 下标 → `structure.columns` 下标。
    private var structureIndexes: [Int] = []
    private var rows: [GridRowItem] = []
    private var appearance = GridAppearance()
    private var failedRow: RowIdentity?
    private var showsInsertRow = false

    private var lastFocusedRow: RowIdentity?
    private var lastFocusedColumn: String?
    private var lastFailedRow: RowIdentity?
    private var lastSelectedIndexes = IndexSet()
    private var lastColumnSignature: [String] = []
    private var isApplyingState = false
    private var isConfiguringColumns = false

    // 右键菜单命中的位置
    private var menuRow = -1
    private var menuColumn = -1
    /// 列头右键命中的列下标（含 `#` 行号列）。
    private var headerMenuColumn = -1

    init(preferences: PreferencesStore) {
        self.preferences = preferences
        super.init()
    }

    // MARK: 行数据

    private struct GridRowItem {
        var identity: RowIdentity
        /// 与 `specs`（可见列）一一对应。
        var values: [CellValue]
        var truncatedLengths: [String: Int]
        var loadedFullColumns: Set<String>
        var changeKind: PendingRowChange.Kind?
        var changedColumns: Set<String>
        var isFocused: Bool
        var isFailed: Bool
        var fingerprint: Int
    }

    var insertRowIndex: Int {
        showsInsertRow ? rows.count : -1
    }

    // MARK: 入口

    func configure(tableView: DataGridTableView) {
        self.tableView = tableView
        tableView.interactionDelegate = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = {
            let header = DataGridHeaderView()
            header.interactionDelegate = self
            return header
        }()
        tableView.usesAlternatingRowBackgroundColors = appearance.alternatingRows
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.selectionHighlightStyle = .none
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: tableView
        )
    }

    /// `updateNSView` 的唯一入口。
    func update(model: TableDataViewModel,
                preferences: PreferencesStore,
                appearance: GridAppearance,
                failedRow: RowIdentity?) {
        self.model = model
        self.failedRow = failedRow

        let newSpecs = makeColumnSpecs(from: model)
        let signature = newSpecs.map(\.name)
        if signature != lastColumnSignature {
            specs = newSpecs
            rebuildColumns()
        } else {
            specs = newSpecs
        }

        if appearance != self.appearance {
            self.appearance = appearance
            tableView?.usesAlternatingRowBackgroundColors = appearance.alternatingRows
        }

        let previous = rows
        let newRows = makeRows(from: model)
        let previousIdentities = previous.map(\.identity)
        let newIdentities = newRows.map(\.identity)
        let newShowsInsertRow = model.editability.isEditable
        let insertRowVisibilityChanged = newShowsInsertRow != showsInsertRow
        showsInsertRow = newShowsInsertRow

        if previousIdentities != newIdentities || insertRowVisibilityChanged {
            rows = newRows
            lastSelectedIndexes = []
            tableView?.reloadData()
            applySelectionState()
        } else {
            var changedIndexes = IndexSet()
            for index in newRows.indices where previous[index].fingerprint != newRows[index].fingerprint {
                changedIndexes.insert(index)
            }
            rows = newRows
            if !changedIndexes.isEmpty, let tableView {
                tableView.reloadData(forRowIndexes: changedIndexes,
                                     columnIndexes: IndexSet(0..<tableView.numberOfColumns))
            }
            applySelectionState()
        }

        // 焦点列变化（同一行内）也要重绘焦点框。
        if lastFocusedColumn != model.focusedColumn || lastFailedRow != failedRow {
            if let focused = model.focusedRow,
               let index = rows.firstIndex(where: { $0.identity == focused }) {
                reloadRow(at: index)
            }
        }
        lastFocusedRow = model.focusedRow
        lastFocusedColumn = model.focusedColumn
        lastFailedRow = failedRow
    }

    // MARK: 列

    private func makeColumnSpecs(from model: TableDataViewModel) -> [GridColumnSpec] {
        guard let structure = model.structure else { return [] }
        let foreignColumns = Set(structure.foreignKeys.flatMap(\.columns))
        let allColumns = structure.columns
        structureIndexes = []
        var specs: [GridColumnSpec] = []
        for column in model.visibleColumns {
            guard let index = allColumns.firstIndex(where: { $0.name == column.name }) else { continue }
            structureIndexes.append(index)
            specs.append(GridColumnSpec(
                name: column.name,
                kind: column.kind,
                isPrimaryKey: column.isPrimaryKey,
                isForeignKey: foreignColumns.contains(column.name),
                rawTypeText: column.rawTypeText,
                isNullable: column.isNullable,
                dataType: column.dataType
            ))
        }
        return specs
    }

    private func rebuildColumns() {
        guard let tableView, let model else { return }
        isConfiguringColumns = true
        defer { isConfiguringColumns = false }

        lastColumnSignature = specs.map(\.name)
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }

        let rowNumber = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__mtl_rownum"))
        rowNumber.title = "#"
        rowNumber.width = 52
        rowNumber.minWidth = 52
        rowNumber.maxWidth = 52
        rowNumber.resizingMask = []
        tableView.addTableColumn(rowNumber)

        for spec in specs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.name))
            column.headerToolTip = spec.headerToolTip
            column.headerCell = makeHeaderCell(for: spec)
            column.width = model.columnWidths[spec.name] ?? estimatedWidth(for: spec)
            column.minWidth = 40
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
    }

    private func makeHeaderCell(for spec: GridColumnSpec) -> NSTableHeaderCell {
        let cell = NSTableHeaderCell()
        var title = spec.name
        if spec.isPrimaryKey { title = "🔑 " + title }
        if spec.isForeignKey { title += " ↗" }
        let font = spec.isPrimaryKey
            ? NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        cell.attributedStringValue = NSAttributedString(string: title, attributes: [.font: font])
        cell.alignment = .left
        return cell
    }

    private func estimatedWidth(for spec: GridColumnSpec) -> Double {
        var width = Double(spec.name.count) * 8 + 24
        if spec.isPrimaryKey { width += 18 }
        for item in rows.prefix(20) {
            guard let index = specs.firstIndex(where: { $0.name == spec.name }),
                  index < item.values.count else { continue }
            let text = item.values[index].displayText
            width = max(width, Double(text.count) * 8 + 20)
        }
        return min(max(width, 60), 400)
    }

    @objc private func columnDidResize(_ notification: Notification) {
        guard !isConfiguringColumns, let model else { return }
        guard let resized = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        let name = resized.identifier.rawValue
        guard name != "__mtl_rownum", specs.contains(where: { $0.name == name }) else { return }
        model.setColumnWidth(Double(resized.width), column: name)
    }

    // MARK: 行

    private func makeRows(from model: TableDataViewModel) -> [GridRowItem] {
        var changeMap: [RowIdentity: PendingRowChange] = [:]
        for change in model.pending.changes { changeMap[change.identity] = change }

        let display = model.displayRows
        var items: [GridRowItem] = []
        items.reserveCapacity(display.count)
        for row in display {
            var values = structureIndexes.map { index -> CellValue in
                index < row.values.count ? row.values[index] : .null
            }
            var loaded: Set<String> = []
            if let full = model.fullValues[row.identity] {
                for (name, value) in full {
                    if let specIndex = specs.firstIndex(where: { $0.name == name }) {
                        values[specIndex] = value
                        loaded.insert(name)
                    }
                }
            }
            let change = changeMap[row.identity]
            let isFocused = model.focusedRow == row.identity
            let isFailed = failedRow == row.identity

            var hasher = Hasher()
            hasher.combine(row.identity)
            hasher.combine(change)
            hasher.combine(loaded)
            hasher.combine(row.truncatedLengths)
            hasher.combine(isFocused)
            hasher.combine(isFailed)
            items.append(GridRowItem(
                identity: row.identity,
                values: values,
                truncatedLengths: row.truncatedLengths,
                loadedFullColumns: loaded,
                changeKind: change?.kind,
                changedColumns: change.map { Set($0.values.keys) } ?? [],
                isFocused: isFocused,
                isFailed: isFailed,
                fingerprint: hasher.finalize()
            ))
        }
        return items
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count + (showsInsertRow ? 1 : 0)
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model else { return nil }
        guard let tableColumn else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")

        if row == insertRowIndex {
            let cell = dequeueCell(identifier: identifier, in: tableView)
            let isRowNumber = tableColumn.identifier.rawValue == "__mtl_rownum"
            let isFirstDataColumn = specs.first?.name == tableColumn.identifier.rawValue
            let text: String
            if isRowNumber {
                text = "＋"
            } else if isFirstDataColumn {
                text = rows.isEmpty ? "插入第一行" : "插入行"
            } else {
                text = ""
            }
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: appearance.fontSize),
                .foregroundColor: NSColor.systemGreen
            ])
            cell.configure(attributed: attributed, stateColor: nil, isSelected: false,
                           isFocused: false, isPlaceholder: true)
            return cell
        }

        guard row >= 0, row < rows.count else { return nil }
        let item = rows[row]
        if tableColumn.identifier.rawValue == "__mtl_rownum" {
            return makeRowNumberCell(item: item, row: row, in: tableView, identifier: identifier)
        }
        guard let columnIndex = specs.firstIndex(where: { $0.name == tableColumn.identifier.rawValue }) else {
            return nil
        }
        let spec = specs[columnIndex]
        let value = columnIndex < item.values.count ? item.values[columnIndex] : .null
        let cell = dequeueCell(identifier: identifier, in: tableView)

        let isTruncated = item.truncatedLengths[spec.name] != nil
            && !item.loadedFullColumns.contains(spec.name)
        let display = displayText(value: value, spec: spec, isTruncated: isTruncated)
        cell.configure(attributed: display.attributed,
                       stateColor: stateColor(item: item, spec: spec),
                       isSelected: tableView.selectedRowIndexes.contains(row),
                       isFocused: item.isFocused && model.focusedColumn == spec.name,
                       isPlaceholder: false)
        cell.toolTip = makeToolTip(value: value, spec: spec, item: item, isTruncated: isTruncated)
        return cell
    }

    private func makeRowNumberCell(item: GridRowItem,
                                   row: Int,
                                   in tableView: NSTableView,
                                   identifier: NSUserInterfaceItemIdentifier) -> NSView {
        let cell = dequeueCell(identifier: identifier, in: tableView)
        let number: String
        switch item.changeKind {
        case .insert: number = "+"
        case .delete: number = "\(row + 1)"
        default: number = "\(row + 1)"
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: appearance.fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        if item.changeKind == .insert {
            attributes[.foregroundColor] = NSColor.systemGreen
        }
        if item.changeKind == .delete {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if item.isFailed {
            attributes[.foregroundColor] = NSColor.systemRed
        }
        let attributed = NSAttributedString(string: item.isFailed ? "! \(number)" : number, attributes: attributes)
        cell.configure(attributed: attributed,
                       stateColor: stateColor(item: item, spec: nil),
                       isSelected: tableView.selectedRowIndexes.contains(row),
                       isFocused: false,
                       isPlaceholder: false)
        cell.toolTip = nil
        return cell
    }

    private func dequeueCell(identifier: NSUserInterfaceItemIdentifier,
                             in tableView: NSTableView) -> GridCellView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? GridCellView {
            return reused
        }
        let cell = GridCellView()
        cell.identifier = identifier
        return cell
    }

    private func displayText(value: CellValue,
                             spec: GridColumnSpec,
                             isTruncated: Bool) -> (attributed: NSAttributedString, plain: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let baseFont: NSFont = spec.kind.isNumeric
            ? NSFont.monospacedDigitSystemFont(ofSize: appearance.fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: appearance.fontSize)
        paragraph.alignment = spec.kind.isNumeric ? .right : .left

        var attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor
        ]

        let text: String
        switch value {
        case .null:
            text = appearance.nullText
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            attributes[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        case .bytes(let bytes):
            if spec.kind.isBinaryLike || String(bytes: bytes, encoding: .utf8) == nil {
                text = GridValueFormatter.binaryPlaceholder(kind: spec.kind, bytes: bytes)
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            } else {
                var plain = String(decoding: bytes, as: UTF8.self)
                if plain.count > 2000 {
                    plain = String(plain.prefix(2000))
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                }
                if isTruncated {
                    plain += "…"
                }
                text = plain
            }
        }

        if spec.isForeignKey, !value.isNull {
            let suffix = NSAttributedString(string: " ↗", attributes: [
                .font: NSFont.systemFont(ofSize: appearance.fontSize - 2),
                .foregroundColor: NSColor.tertiaryLabelColor
            ])
            let result = NSMutableAttributedString(string: text, attributes: attributes)
            result.append(suffix)
            return (result, text)
        }
        return (NSAttributedString(string: text, attributes: attributes), text)
    }

    private func makeToolTip(value: CellValue,
                             spec: GridColumnSpec,
                             item: GridRowItem,
                             isTruncated: Bool) -> String? {
        if case .null = value {
            return appearance.nullText
        }
        if isTruncated, let length = item.truncatedLengths[spec.name] {
            return "原始内容 \(GridValueFormatter.byteCount(length))，点开可查看完整内容"
        }
        return nil
    }

    private func stateColor(item: GridRowItem, spec: GridColumnSpec?) -> NSColor? {
        if item.isFailed {
            return NSColor.systemRed.withAlphaComponent(0.18)
        }
        switch item.changeKind {
        case .insert:
            return NSColor.systemGreen.withAlphaComponent(0.16)
        case .delete:
            return NSColor.systemRed.withAlphaComponent(0.12)
        case .update:
            if let spec, item.changedColumns.contains(spec.name) {
                return NSColor.systemOrange.withAlphaComponent(0.22)
            }
            return nil
        case nil:
            return nil
        }
    }

    // MARK: 选择

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingState, let model, let tableView else { return }
        let selectedIndexes = tableView.selectedRowIndexes
        let previouslySelected = lastSelectedIndexes
        lastSelectedIndexes = selectedIndexes

        let identities = Set(selectedIndexes.compactMap { index -> RowIdentity? in
            guard index >= 0, index < rows.count else { return nil }
            return rows[index].identity
        })
        if identities != model.selectedRows {
            model.selectedRows = identities
        }
        if let focused = model.focusedRow, identities.contains(focused) {
            // 焦点仍在选区里，保持
        } else if let first = rows.firstIndex(where: { identities.contains($0.identity) }) {
            model.focusedRow = rows[first].identity
            if model.focusedColumn == nil { model.focusedColumn = specs.first?.name }
        }
        // 重绘旧选与新区，刷新选择底色
        var affected = previouslySelected
        affected.formUnion(selectedIndexes)
        reloadRows(at: affected)
    }

    private func applySelectionState() {
        guard let tableView, let model else { return }
        var desired = model.selectedRows
        if desired.isEmpty, let focused = model.focusedRow { desired = [focused] }
        var indexes = IndexSet()
        for (index, item) in rows.enumerated() where desired.contains(item.identity) {
            indexes.insert(index)
        }
        guard tableView.selectedRowIndexes != indexes else { return }
        isApplyingState = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        isApplyingState = false
        lastSelectedIndexes = indexes
    }

    private func reloadRows(at indexes: IndexSet) {
        guard let tableView, !indexes.isEmpty else { return }
        let valid = indexes.filteredIndexSet { $0 >= 0 && $0 < rows.count }
        guard !valid.isEmpty else { return }
        tableView.reloadData(forRowIndexes: valid, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
    }

    private func reloadRow(at index: Int) {
        guard index >= 0, index < rows.count else { return }
        reloadRows(at: IndexSet(integer: index))
    }

    // MARK: 交互

    func handleInsertRowClick() {
        guard let model, model.editability.isEditable else { return }
        model.insertRow()
    }

    func handleCellClick(row: Int, column: Int) {
        guard let model, row >= 0, row < rows.count else { return }
        guard column >= 0 else { return }
        if column == 0 {
            model.focusedRow = rows[row].identity
            if model.focusedColumn == nil { model.focusedColumn = specs.first?.name }
            return
        }
        let specIndex = column - 1
        guard specIndex < specs.count else { return }
        model.focusedRow = rows[row].identity
        model.focusedColumn = specs[specIndex].name
    }

    func handleQuickLook(row: Int, column: Int) {
        guard let model, row >= 0, row < rows.count, column >= 1 else { return }
        let specIndex = column - 1
        guard specIndex < specs.count else { return }
        let identity = rows[row].identity
        model.focusedRow = identity
        model.focusedColumn = specs[specIndex].name
        onQuickLook?(identity, specs[specIndex].name)
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        guard let model, let tableView else { return }
        let row = tableView.clickedRow
        let column = tableView.clickedColumn
        guard row >= 0, row < rows.count, column >= 1, column - 1 < specs.count else { return }
        let identity = rows[row].identity
        let columnName = specs[column - 1].name
        model.focusedRow = identity
        model.focusedColumn = columnName
        let isDeleted = model.pending.change(for: identity)?.kind == .delete
        if model.editability.isEditable, !isDeleted {
            onBeginEdit?(identity, columnName)
        } else {
            onQuickLook?(identity, columnName)
        }
    }

    /// 返回 true 表示已处理，吞掉该按键。
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 123, 124, 125, 126: // ← → ↓ ↑
            let horizontal = event.keyCode == 123 || event.keyCode == 124
            let positive = event.keyCode == 124 || event.keyCode == 125
            if flags.contains(.command) {
                moveFocusToEdge(horizontal: horizontal, positive: positive)
            } else {
                moveFocus(horizontal: horizontal, positive: positive)
            }
            return true
        case 49: // Space
            guard !flags.contains(.command), let focused = model.focusedRow,
                  let column = model.focusedColumn else { return false }
            onQuickLook?(focused, column)
            return true
        case 36: // Return
            guard !flags.contains(.command), let focused = model.focusedRow,
                  let column = model.focusedColumn else { return false }
            let isDeleted = model.pending.change(for: focused)?.kind == .delete
            if model.editability.isEditable, !isDeleted {
                onBeginEdit?(focused, column)
            } else {
                onQuickLook?(focused, column)
            }
            return true
        case 51, 117: // Delete / Forward Delete
            let targets = selectedOrFocusedRows()
            guard !targets.isEmpty else { return false }
            model.deleteRows(targets)
            return true
        case 48: // Tab
            moveFocus(horizontal: true, positive: !flags.contains(.shift))
            return true
        default:
            break
        }

        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                performCopy(kind: model.selectedRows.count > 1 ? .selectedRows : .cell)
                return true
            case "i":
                handleInsertRowClick()
                return true
            case "d":
                let targets = selectedOrFocusedRows()
                guard !targets.isEmpty else { return true }
                model.duplicateRows(targets)
                return true
            case "p" where flags.contains(.shift):
                onRequestPreview?()
                return true
            case "s":
                onRequestCommit?()
                return true
            default:
                break
            }
            // ⇧⌘⌫ 放弃全部修改
            if event.keyCode == 51, flags.contains(.shift) {
                onRequestDiscard?()
                return true
            }
            return false
        }
        return false
    }

    private func selectedOrFocusedRows() -> Set<RowIdentity> {
        guard let model else { return [] }
        if !model.selectedRows.isEmpty { return model.selectedRows }
        if let focused = model.focusedRow { return [focused] }
        return []
    }

    private func moveFocus(horizontal: Bool, positive: Bool) {
        guard let model else { return }
        guard let focused = model.focusedRow,
              let column = model.focusedColumn,
              let rowIndex = rows.firstIndex(where: { $0.identity == focused }),
              let specIndex = specs.firstIndex(where: { $0.name == column }) else {
            focusFirstCell()
            return
        }
        var newRow = rowIndex
        var newSpec = specIndex
        if horizontal {
            newSpec += positive ? 1 : -1
            if newSpec >= specs.count {
                newSpec = 0
                newRow += 1
            } else if newSpec < 0 {
                newSpec = specs.count - 1
                newRow -= 1
            }
        } else {
            newRow += positive ? 1 : -1
        }
        guard newRow >= 0, newRow < rows.count, newSpec >= 0, newSpec < specs.count else { return }
        let identity = rows[newRow].identity
        model.focusedRow = identity
        model.focusedColumn = specs[newSpec].name
        model.selectedRows = [identity]
        scrollToCell(row: newRow, column: newSpec)
    }

    private func moveFocusToEdge(horizontal: Bool, positive: Bool) {
        guard let model, !rows.isEmpty, !specs.isEmpty else { return }
        guard let focused = model.focusedRow,
              let rowIndex = rows.firstIndex(where: { $0.identity == focused }) else {
            focusFirstCell()
            return
        }
        if horizontal {
            model.focusedColumn = (positive ? specs.last : specs.first)?.name
            scrollToCell(row: rowIndex, column: positive ? specs.count - 1 : 0)
        } else {
            let target = positive ? rows.count - 1 : 0
            model.focusedRow = rows[target].identity
            model.selectedRows = [rows[target].identity]
            if let specIndex = specs.firstIndex(where: { $0.name == model.focusedColumn }) {
                scrollToCell(row: target, column: specIndex)
            }
        }
    }

    private func focusFirstCell() {
        guard let model, let first = rows.first, let spec = specs.first else { return }
        model.focusedRow = first.identity
        model.focusedColumn = spec.name
        model.selectedRows = [first.identity]
    }

    private func scrollToCell(row: Int, column: Int) {
        guard let tableView else { return }
        let columnIndex = column + 1
        guard columnIndex < tableView.numberOfColumns else { return }
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(columnIndex)
    }

    // MARK: 右键菜单

    func prepareContextMenu(row: Int, column: Int) {
        menuRow = row
        menuColumn = column
    }

    func prepareHeaderContextMenu(column: Int) {
        headerMenuColumn = column
    }

    /// 列头右键菜单：只放「按此列筛选」。
    func makeHeaderContextMenu() -> NSMenu? {
        guard onFilterByColumn != nil,
              headerMenuColumn >= 1,
              headerMenuColumn - 1 < specs.count else { return nil }
        let menu = NSMenu()
        let filter = NSMenuItem(title: "按此列筛选",
                                action: #selector(headerFilterMenuItem(_:)),
                                keyEquivalent: "")
        filter.target = self
        menu.addItem(filter)
        return menu
    }

    @objc private func headerFilterMenuItem(_ sender: NSMenuItem) {
        guard headerMenuColumn >= 1, headerMenuColumn - 1 < specs.count else { return }
        onFilterByColumn?(specs[headerMenuColumn - 1].name)
    }

    func makeContextMenu() -> NSMenu? {
        guard let model, menuRow >= 0, menuRow < rows.count else {
            return emptyAreaMenu()
        }
        let menu = NSMenu()
        let copyRoot = NSMenuItem(title: "复制为", action: nil, keyEquivalent: "")
        let copyMenu = NSMenu()
        for kind in GridCopyKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(copyMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            copyMenu.addItem(item)
        }
        copyRoot.submenu = copyMenu
        menu.addItem(copyRoot)

        if onFilterByValue != nil, menuColumn >= 1, menuColumn - 1 < specs.count {
            let filter = NSMenuItem(title: "按此值筛选", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
            filter.target = self
            filter.tag = GridCommand.filterByValue.rawValue
            menu.addItem(filter)
            let exclude = NSMenuItem(title: "排除此值", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
            exclude.target = self
            exclude.tag = GridCommand.excludeValue.rawValue
            menu.addItem(exclude)
        }

        menu.addItem(.separator())

        let insert = NSMenuItem(title: "插入行", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
        insert.target = self
        insert.tag = GridCommand.insertRow.rawValue
        insert.isEnabled = model.editability.isEditable
        menu.addItem(insert)

        let duplicate = NSMenuItem(title: "复制行", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
        duplicate.target = self
        duplicate.tag = GridCommand.duplicateRows.rawValue
        duplicate.isEnabled = model.editability.isEditable
        menu.addItem(duplicate)

        let delete = NSMenuItem(title: "删除行", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
        delete.target = self
        delete.tag = GridCommand.deleteRows.rawValue
        delete.isEnabled = model.editability.isEditable
        menu.addItem(delete)

        if let identity = rows[safe: menuRow]?.identity, model.pending.change(for: identity) != nil {
            let undo = NSMenuItem(title: "撤销该行的修改", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
            undo.target = self
            undo.tag = GridCommand.undoRow.rawValue
            menu.addItem(undo)
        }

        menu.addItem(.separator())

        let quickLook = NSMenuItem(title: "快速查看", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
        quickLook.target = self
        quickLook.tag = GridCommand.quickLook.rawValue
        quickLook.isEnabled = menuColumn >= 1
        menu.addItem(quickLook)

        let export = NSMenuItem(title: "导出选中行…", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
        export.target = self
        export.tag = GridCommand.exportSelected.rawValue
        export.isEnabled = onExportSelected != nil && !model.selectedRows.isEmpty
        menu.addItem(export)

        if menuColumn >= 1, menuColumn - 1 < specs.count, specs[menuColumn - 1].isForeignKey {
            let jump = NSMenuItem(title: "打开被引用的行", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
            jump.target = self
            jump.tag = GridCommand.foreignKeyJump.rawValue
            menu.addItem(jump)
        }
        return menu
    }

    private func emptyAreaMenu() -> NSMenu {
        let menu = NSMenu()
        let insert = NSMenuItem(title: "插入行", action: #selector(commandMenuItem(_:)), keyEquivalent: "")
        insert.target = self
        insert.tag = GridCommand.insertRow.rawValue
        insert.isEnabled = model?.editability.isEditable ?? false
        menu.addItem(insert)
        return menu
    }

    private enum GridCommand: Int {
        case filterByValue
        case excludeValue
        case insertRow
        case duplicateRows
        case deleteRows
        case undoRow
        case quickLook
        case exportSelected
        case foreignKeyJump
    }

    @objc private func commandMenuItem(_ sender: NSMenuItem) {
        guard let model, let command = GridCommand(rawValue: sender.tag) else { return }
        let identity = (menuRow >= 0 && menuRow < rows.count) ? rows[menuRow].identity : nil
        switch command {
        case .filterByValue, .excludeValue:
            guard menuColumn >= 1, menuColumn - 1 < specs.count, let identity,
                  let index = rows.firstIndex(where: { $0.identity == identity }) else { return }
            let spec = specs[menuColumn - 1]
            let value = index < rows.count ? rows[index].values[menuColumn - 1] : .null
            onFilterByValue?(spec.name, value, command == .excludeValue)
        case .insertRow:
            handleInsertRowClick()
        case .duplicateRows:
            let targets = menuSelection(fallback: identity)
            model.duplicateRows(targets)
        case .deleteRows:
            let targets = menuSelection(fallback: identity)
            model.deleteRows(targets)
        case .undoRow:
            if let identity { model.undoRow(identity) }
        case .quickLook:
            if identity != nil { handleQuickLook(row: menuRow, column: menuColumn) }
        case .exportSelected:
            let targets = menuSelection(fallback: identity)
            onExportSelected?(targets)
        case .foreignKeyJump:
            guard menuColumn >= 1, menuColumn - 1 < specs.count, let identity,
                  let index = rows.firstIndex(where: { $0.identity == identity }) else { return }
            let spec = specs[menuColumn - 1]
            let value = rows[index].values[menuColumn - 1]
            onForeignKeyJump?(identity, spec.name, value)
        }
    }

    private func menuSelection(fallback: RowIdentity?) -> Set<RowIdentity> {
        if let model, !model.selectedRows.isEmpty { return model.selectedRows }
        if let fallback { return [fallback] }
        return []
    }

    @objc private func copyMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = GridCopyKind(rawValue: raw) else { return }
        performCopy(kind: kind)
    }

    // MARK: 复制

    private func performCopy(kind: GridCopyKind) {
        guard let model else { return }
        // 目标行
        let contextRow = (menuRow >= 0 && menuRow < rows.count) ? menuRow : nil
        func rowItems(for identities: Set<RowIdentity>) -> [GridRowItem] {
            rows.filter { identities.contains($0.identity) }
        }

        let selected = model.selectedRows
        switch kind {
        case .cell:
            guard let contextRow else { return }
            let item = rows[contextRow]
            guard menuColumn >= 1, menuColumn - 1 < specs.count else { return }
            let text = GridCopyFormatter.cellText(item.values[menuColumn - 1],
                                                  column: tableColumn(at: menuColumn - 1),
                                                  nullText: appearance.nullText)
            writeToPasteboard(text)
            onToast?("已复制单元格")
        case .row:
            guard let contextRow else { return }
            let item = rows[contextRow]
            let text = GridCopyFormatter.rowText(makeTableRow(item), columns: tableColumns(),
                                                 nullText: appearance.nullText)
            writeToPasteboard(text)
            onToast?("已复制 1 行")
        case .selectedRows:
            let items = selected.isEmpty ? (contextRow.map { [rows[$0]] } ?? []) : rowItems(for: selected)
            guard !items.isEmpty else { return }
            let text = GridCopyFormatter.rowsText(items.map(makeTableRow), columns: tableColumns(),
                                                  nullText: appearance.nullText)
            writeToPasteboard(text, rowCount: items.count)
        case .column:
            guard menuColumn >= 1, menuColumn - 1 < specs.count else { return }
            let specIndex = menuColumn - 1
            let text = GridCopyFormatter.columnText(rows.map(makeTableRow),
                                                    column: tableColumn(at: specIndex),
                                                    index: specIndex,
                                                    nullText: appearance.nullText)
            writeToPasteboard(text, rowCount: rows.count)
        case .columnNames:
            writeToPasteboard(GridCopyFormatter.columnNames(tableColumns()))
            onToast?("已复制列名")
        case .json:
            let items = copyTargetRows(selected: selected, contextRow: contextRow)
            writeToPasteboard(GridCopyFormatter.json(items.map(makeTableRow), columns: tableColumns()),
                              rowCount: items.count)
        case .markdown:
            let items = copyTargetRows(selected: selected, contextRow: contextRow)
            writeToPasteboard(GridCopyFormatter.markdown(items.map(makeTableRow), columns: tableColumns(),
                                                          nullText: appearance.nullText),
                              rowCount: items.count)
        case .csv, .csvWithHeader:
            let items = copyTargetRows(selected: selected, contextRow: contextRow)
            let text = GridCopyFormatter.csv(items.map(makeTableRow), columns: tableColumns(),
                                             delimiter: preferences.csvDelimiter.character,
                                             includeHeader: kind == .csvWithHeader,
                                             nullStyle: preferences.csvNullStyle)
            writeToPasteboard(text, rowCount: items.count)
        case .sqlInsert:
            let items = copyTargetRows(selected: selected, contextRow: contextRow)
            guard !items.isEmpty, model.structure != nil else { return }
            let ref = model.ref
            let columns = tableColumns()
            let tableRows = items.map(makeTableRow)
            Task { [weak self] in
                guard let self else { return }
                let literalizer = await self.literalizerProvider?() ?? .conservative
                let text = GridCopyFormatter.sqlInsert(ref: ref, rows: tableRows,
                                                       columns: columns, using: literalizer)
                self.writeToPasteboard(text, rowCount: tableRows.count)
            }
        case .createStatement:
            guard let structure = model.structure else { return }
            let text = GridCopyFormatter.createStatement(structure)
            guard !text.isEmpty else { return }
            writeToPasteboard(text)
            onToast?("已复制表结构")
        }
    }

    private func copyTargetRows(selected: Set<RowIdentity>, contextRow: Int?) -> [GridRowItem] {
        if !selected.isEmpty { return rows.filter { selected.contains($0.identity) } }
        if let contextRow, contextRow >= 0, contextRow < rows.count { return [rows[contextRow]] }
        return []
    }

    private func tableColumns() -> [TableColumn] {
        specs.map { spec in
            TableColumn(name: spec.name, dataType: spec.dataType, rawTypeText: spec.rawTypeText,
                        isNullable: spec.isNullable, isPrimaryKey: spec.isPrimaryKey, kind: spec.kind)
        }
    }

    private func tableColumn(at index: Int) -> TableColumn {
        tableColumns()[index]
    }

    private func makeTableRow(_ item: GridRowItem) -> TableDataRow {
        TableDataRow(identity: item.identity, values: item.values, truncatedLengths: item.truncatedLengths)
    }

    private func writeToPasteboard(_ text: String, rowCount: Int? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard let rowCount else { return }
        if rowCount > 100 {
            let bytes = text.lengthOfBytes(using: .utf8)
            onToast?("已复制 \(TableDataViewModelLogic.groupedDigits(rowCount)) 行（\(GridValueFormatter.byteCount(bytes))）")
        } else {
            onToast?("已复制 \(rowCount) 行")
        }
    }
}

// MARK: - 小工具

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
