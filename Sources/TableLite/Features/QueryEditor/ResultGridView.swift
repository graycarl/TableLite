import AppKit
import SwiftUI

// MARK: - 结果展示
//
// 结果网格是**只读**的：本地排序、列宽、列显隐、复制、快速查看（Space / 中键 / 右键）。
// 见 specs/06-query-editor.md §4、specs/02-workspace.md §9、docs/tech-designs/10-query-editor.md §6。
//
// 网格用精简只读 `NSTableView`（不复用表数据视图，避免与并行开发耦合）。

struct ResultGridView: View {
    let result: QueryResult

    var body: some View {
        switch result.kind {
        case .rows(let set):
            if set.rows.isEmpty {
                ResultPlaceholderView(
                    systemImage: "checkmark.circle",
                    title: "查询成功，0 行",
                    detail: "耗时 \(QueryTabLogic.elapsedText(result.elapsed))"
                )
            } else {
                ResultSetView(set: set, elapsed: result.elapsed)
            }
        case .affected(let header):
            AffectedResultView(header: header, elapsed: result.elapsed)
        case .error(let error):
            ErrorResultView(error: error, statement: result.statement)
        case .rejected(let reason):
            RejectedResultView(reason: reason, statement: result.statement)
        }
    }
}

// MARK: - 有行的结果

private struct ResultSetView: View {
    let set: MaterializedResultSet
    let elapsed: Duration

    @EnvironmentObject private var toasts: ToastCenter
    @State private var hiddenColumns: Set<Int> = []
    @State private var quickLookController = QuickLookPanelController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(QueryTabLogic.grouped(set.rows.count)) 行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· 耗时 \(QueryTabLogic.elapsedText(elapsed))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                columnMenu
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            ReadOnlyResultTable(
                header: set.header,
                rows: set.rows,
                hiddenColumns: hiddenColumns,
                onCopied: { count in
                    toasts.show("已复制 \(QueryTabLogic.grouped(count)) 行", actionTitle: nil, action: nil)
                },
                onQuickLook: presentQuickLook
            )
        }
    }

    /// 结果集已全部在内存里，无需两阶段加载，直接展示完整单元格。
    private func presentQuickLook(value: CellValue, columnIndex: Int, row: Int) {
        guard set.header.columns.indices.contains(columnIndex) else { return }
        let column = set.header.columns[columnIndex]
        let name = column.name.isEmpty ? "列 \(columnIndex + 1)" : column.name
        quickLookController.show(title: "\(name) · 第 \(row + 1) 行",
                                 kind: column.kind,
                                 value: value,
                                 isLoading: false,
                                 error: nil)
    }

    private var columnMenu: some View {
        Menu {
            ForEach(Array(set.header.columns.enumerated()), id: \.offset) { index, column in
                Toggle(isOn: Binding(
                    get: { !hiddenColumns.contains(index) },
                    set: { visible in
                        if visible { hiddenColumns.remove(index) } else { hiddenColumns.insert(index) }
                    }
                )) {
                    Text(column.name.isEmpty ? "列 \(index + 1)" : column.name)
                }
            }
        } label: {
            Label("列", systemImage: "eye")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - 只读网格（AppKit）

private struct ReadOnlyResultTable: NSViewRepresentable {
    let header: ResultSetHeader
    let rows: [[CellValue]]
    let hiddenColumns: Set<Int>
    let onCopied: (Int) -> Void
    let onQuickLook: (CellValue, Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = ResultTableView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.headerView = NSTableHeaderView()
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = false

        for (index, column) in header.columns.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier("col-\(index)")
            let tableColumn = NSTableColumn(identifier: identifier)
            tableColumn.title = column.name.isEmpty ? "列 \(index + 1)" : column.name
            tableColumn.width = 150
            tableColumn.minWidth = 40
            tableColumn.resizingMask = [.userResizingMask, .autoresizingMask]
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            tableView.addTableColumn(tableColumn)
        }

        context.coordinator.tableView = tableView
        context.coordinator.rows = rows
        context.coordinator.sortedRows = rows
        context.coordinator.appliedCount = rows.count
        context.coordinator.appliedTail = Coordinator.tailSignature(rows)
        context.coordinator.appliedHeader = header
        context.coordinator.onCopied = onCopied
        context.coordinator.configureCopy()
        context.coordinator.configureQuickLook()
        context.coordinator.applyHiddenColumns(hiddenColumns)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(header: header, rows: rows, hiddenColumns: hiddenColumns)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ReadOnlyResultTable
        weak var tableView: ResultTableView?
        var rows: [[CellValue]] = []
        var sortedRows: [[CellValue]] = []
        var appliedCount = -1
        var appliedTail = -1
        var appliedHeader: ResultSetHeader?
        var onCopied: ((Int) -> Void)?
        private var sortKey: Int?
        private var sortAscending = true

        init(_ parent: ReadOnlyResultTable) {
            self.parent = parent
        }

        static func tailSignature(_ rows: [[CellValue]]) -> Int {
            guard let last = rows.last else { return -1 }
            return last.reduce(0) { $0 &+ $1.byteCount } &+ last.count
        }

        func update(header: ResultSetHeader, rows: [[CellValue]], hiddenColumns: Set<Int>) {
            guard let tableView else { return }
            let tail = Self.tailSignature(rows)
            if appliedCount != rows.count || appliedTail != tail || appliedHeader != header {
                self.rows = rows
                appliedCount = rows.count
                appliedTail = tail
                appliedHeader = header
                applySort()
                tableView.reloadData()
            }
            for (index, column) in tableView.tableColumns.enumerated() {
                if index < header.columns.count {
                    let name = header.columns[index].name
                    column.title = name.isEmpty ? "列 \(index + 1)" : name
                }
            }
            applyHiddenColumns(hiddenColumns)
        }

        func applyHiddenColumns(_ hidden: Set<Int>) {
            guard let tableView else { return }
            for (index, column) in tableView.tableColumns.enumerated() {
                column.isHidden = hidden.contains(index)
            }
        }

        func configureCopy() {
            tableView?.onCopy = { [weak self] in self?.copySelectedRows() }
        }

        func configureQuickLook() {
            tableView?.onQuickLook = { [weak self] row, column in
                self?.quickLook(row: row, column: column)
            }
        }

        /// 把当前展示行（可能已本地排序）/ 列映射回单元格值，交给 SwiftUI 侧打开面板。
        func quickLook(row: Int, column: Int) {
            guard row >= 0, row < sortedRows.count else { return }
            guard column >= 0, column < sortedRows[row].count else { return }
            parent.onQuickLook(sortedRows[row][column], column, row)
        }

        private func applySort() {
            guard let sortKey else {
                sortedRows = rows
                return
            }
            let ascending = sortAscending
            sortedRows = rows.sorted { lhs, rhs in
                let left = sortKey < lhs.count ? lhs[sortKey] : .null
                let right = sortKey < rhs.count ? rhs[sortKey] : .null
                return Self.less(left, right, ascending: ascending)
            }
        }

        private static func less(_ lhs: CellValue, _ rhs: CellValue, ascending: Bool) -> Bool {
            if lhs.isNull || rhs.isNull {
                if lhs.isNull && rhs.isNull { return false }
                // NULL 恒排最后（不随升降序翻转）
                return rhs.isNull
            }
            let left = lhs.displayText
            let right = rhs.displayText
            if let leftNumber = Double(left), let rightNumber = Double(right) {
                return ascending ? leftNumber < rightNumber : leftNumber > rightNumber
            }
            let result = left.localizedStandardCompare(right)
            if result == .orderedSame { return false }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        // MARK: 数据源 / 委托

        func numberOfRows(in tableView: NSTableView) -> Int {
            sortedRows.count
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn,
                  let index = Int(tableColumn.identifier.rawValue.dropFirst(4)),
                  row < sortedRows.count,
                  index < sortedRows[row].count else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("result-cell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                field.cell?.usesSingleLineMode = true
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            let value = sortedRows[row][index]
            cell.textField?.stringValue = value.isNull
                ? "NULL"
                : value.displayText.replacingOccurrences(of: "\n", with: "⏎")
            cell.textField?.textColor = value.isNull ? .tertiaryLabelColor : .labelColor
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first else {
                sortKey = nil
                applySort()
                tableView.reloadData()
                return
            }
            sortKey = descriptor.key.flatMap(Int.init)
            sortAscending = descriptor.ascending
            applySort()
            tableView.reloadData()
        }

        // MARK: 复制

        func copySelectedRows() {
            guard let tableView else { return }
            let indexes = tableView.selectedRowIndexes
            let picked: [[CellValue]]
            if indexes.isEmpty {
                picked = sortedRows
            } else {
                picked = indexes.compactMap { $0 < sortedRows.count ? sortedRows[$0] : nil }
            }

            var lines: [String] = [parent.header.columns.map(\.name).joined(separator: "\t")]
            for row in picked {
                lines.append(row.map { $0.isNull ? "NULL" : $0.displayText }.joined(separator: "\t"))
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
            onCopied?(picked.count)
        }
    }
}

/// 支持 `⌘C`、复制、快速查看（`Space` / 中键 / 右键）的只读表格。
@MainActor
private final class ResultTableView: NSTableView, NSMenuItemValidation {
    var onCopy: (() -> Void)?
    /// (展示行, 列索引)；由 Coordinator 映射到 `sortedRows`。
    var onQuickLook: ((_ row: Int, _ column: Int) -> Void)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    @objc func quickLook(_ sender: Any?) {
        onQuickLook?(clickedRow, clickedColumn)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(quickLook(_:)) {
            return clickedRow >= 0 && clickedColumn >= 0
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        // 纯 `Space`：快速查看光标所在的单元格（specs/02-workspace.md §9）。
        let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        if event.keyCode == 49,
           event.modifierFlags.intersection(modifiers).isEmpty,
           selectedRow >= 0, selectedColumn >= 0 {
            onQuickLook?(selectedRow, selectedColumn)
            return
        }
        super.keyDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        // 中键点击：先选中单元格，再快速查看。
        if event.buttonNumber == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let row = self.row(at: point)
            let column = self.column(at: point)
            if row >= 0, column >= 0 {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                onQuickLook?(row, column)
                return
            }
        }
        super.otherMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let quickLookItem = NSMenuItem(title: "快速查看", action: #selector(quickLook(_:)), keyEquivalent: "")
        quickLookItem.target = self
        menu.addItem(quickLookItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let selectAllItem = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        return menu
    }
}

// MARK: - 无返回行的语句

private struct AffectedResultView: View {
    let header: ResultSetHeader
    let elapsed: Duration

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text(message)
                .font(.title3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var message: String {
        var parts = ["影响 \(QueryTabLogic.grouped(Int(header.affectedRows))) 行",
                     "耗时 \(QueryTabLogic.elapsedText(elapsed))"]
        if header.lastInsertID > 0 {
            parts.append("last_insert_id = \(header.lastInsertID)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 错误

private struct ErrorResultView: View {
    let error: MySQLServerError
    let statement: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("执行失败", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("[错误 \(error.code)] SQLSTATE \(error.sqlState)")
                    .font(.headline)
                    .textSelection(.enabled)
                if !error.message.isEmpty {
                    Text(error.message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint = error.chineseHint {
                    Text(hint)
                        .foregroundStyle(.secondary)
                }
                if !statement.isEmpty {
                    StatementBlock(statement: statement)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

// MARK: - 只读拦截

private struct RejectedResultView: View {
    let reason: String
    let statement: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("只读拦截", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(reason)
                    .fixedSize(horizontal: false, vertical: true)
                StatementBlock(statement: statement)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

// MARK: - 公共小组件

private struct StatementBlock: View {
    let statement: String

    var body: some View {
        Text(statement)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ResultPlaceholderView: View {
    let systemImage: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
