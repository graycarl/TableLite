import Foundation

// MARK: - 提交失败

/// 一次提交失败的完整信息，供错误面板原样展示（`specs/04-data-editing.md` §10、`specs/12-feedback.md` §5）。
public struct CommitFailure: Sendable, Equatable {
    /// 失败语句的序号（1-based；`BEGIN` 失败为 1）。
    public var index: Int
    public var statement: String
    /// 服务器错误码；客户端错误 / 取消时为 nil。
    public var code: UInt32?
    public var sqlState: String?
    /// 服务器返回的原文，不翻译、不改写。
    public var message: String
    /// 中文解释行。
    public var explanation: String?
    /// 用户主动取消（在两条语句之间）。
    public var isCancelled: Bool = false
    /// 超时 / 服务器崩溃等无法确定事务是否已结束的情况。
    public var isUnknownTransactionState: Bool = false

    public init(
        index: Int,
        statement: String,
        code: UInt32? = nil,
        sqlState: String? = nil,
        message: String,
        explanation: String? = nil,
        isCancelled: Bool = false,
        isUnknownTransactionState: Bool = false
    ) {
        self.index = index
        self.statement = statement
        self.code = code
        self.sqlState = sqlState
        self.message = message
        self.explanation = explanation
        self.isCancelled = isCancelled
        self.isUnknownTransactionState = isUnknownTransactionState
    }

    /// 错误码与 SQLSTATE 的展示行：`[错误 1062] SQLSTATE 23000`。
    public var codeLine: String? {
        guard let code else { return nil }
        let state = (sqlState?.isEmpty == false) ? sqlState! : "-"
        return "[错误 \(code)] SQLSTATE \(state)"
    }

    /// 面板里的影响说明（`specs/12-feedback.md` §5 规则 3）。
    public var impactText: String {
        if isCancelled {
            return "提交已取消，事务已回滚，你的修改都还在暂存区里，尚未生效。"
        }
        if isUnknownTransactionState {
            return "提交超时，事务状态未知，请在数据库中手动核对这几行的数据。"
        }
        return "事务已回滚，你的修改都还在暂存区里，尚未生效。"
    }

    public var title: String {
        isCancelled ? "提交已取消" : "提交失败"
    }
}

// MARK: - 删除确认

/// 删除行前展示的将执行条件（`specs/04-data-editing.md` §6）。
///
/// 每行一个 `WHERE` 子句（用该行的冻结定位键生成），让用户确认删的是哪一行。
public struct PendingRowDeletion: Sendable, Equatable {
    /// 待删除的行 id（含新增行）。
    public var rowIDs: [String]
    /// 每行将执行的 `WHERE` 条件，例如 `WHERE id = 42`。
    public var conditions: [String]

    public init(rowIDs: [String], conditions: [String]) {
        self.rowIDs = rowIDs
        self.conditions = conditions
    }

    /// 确认弹窗里的说明文案。
    public var message: String {
        let joined = conditions.joined(separator: "\n")
        return conditions.count == 1 ? "将执行：\n\(joined)" : "将执行以下条件：\n\(joined)"
    }
}

// MARK: - 编辑编排

/// `TableDataViewModel` 的编辑 / 暂存 / 提交 / 放弃编排。
///
/// 分工：
/// - 合并规则、定位键冻结、SQL 生成都在 Core（`PendingChangeStore` / `PendingChangeSQL`）；
/// - 本扩展只把 UI 意图翻译成 Core 操作，并维护网格 / 字段栏的展示投影；
/// - 提交与预览走**同一条** SQL 生成路径（`PendingChangeSQL` + `session.mysql.makeEscaper()`，S29）。
@MainActor
extension TableDataViewModel {

    /// 新增行在网格里的合成 id 前缀。
    static let insertionRowPrefix = "insertion:"

    static func insertionRowID(_ id: UUID) -> String {
        insertionRowPrefix + id.uuidString
    }

    /// 表是否可编辑；加载中 / 未加载元数据 / 提交中一律不可编辑。
    var isEditingEnabled: Bool {
        isEditable && isMetadataLoaded && loadState == .loaded && !isCommitting
    }

    // MARK: 字段栏取值

    /// 字段栏当前应显示的值：暂存值 → 完整值 → 首屏值；新增行的未填列为空串。
    public func inspectorValue(rowID: String, column: String) -> SQLValue {
        guard let row = gridRows.first(where: { $0.id == rowID }), let cell = row.cells[column] else {
            return .null
        }
        if row.changeKind == .insertion {
            return cell.draftValue ?? .text("")
        }
        return cell.draftValue ?? cell.fullValue ?? cell.value
    }

    /// 已删除的行在字段栏里全部只读（`specs/04-data-editing.md` §6）。
    public func isRowDeleted(rowID: String) -> Bool {
        gridRows.first(where: { $0.id == rowID })?.changeKind == .deletion
    }

    /// 新增行模式。
    public func isInsertionRow(rowID: String) -> Bool {
        rowID.hasPrefix(Self.insertionRowPrefix)
    }

    /// 网格单元格是否处于「已修改」状态。
    public func isCellEdited(rowID: String, column: String) -> Bool {
        guard let row = gridRows.first(where: { $0.id == rowID }), let cell = row.cells[column] else { return false }
        return cell.isEdited
    }

    public func rowChangeKind(rowID: String) -> GridRowChangeKind? {
        gridRows.first(where: { $0.id == rowID })?.changeKind
    }

    // MARK: 单元格编辑

    /// 把字段栏的一次提交写入暂存区。
    ///
    /// - 大字段尚未加载完整值时先 `ensureFullValue`，在其上应用修改；加载失败则不写入
    ///   （`docs/tech-designs/08-pending-changes.md` §9，AGENTS 坑 §4）。
    /// - 值未变化 → 丢弃；改回原值 → 该列的改动消失（合并规则在 Core）。
    public func applyInspectorEdit(rowID: String, column: String, value: SQLValue) async {
        guard isEditingEnabled else { return }
        guard let row = gridRows.first(where: { $0.id == rowID }), let cell = row.cells[column] else { return }
        guard row.changeKind != .deletion else {
            showToast("这一行已标记删除，请先撤销删除再编辑")
            return
        }
        guard let identity = rowIdentity(for: row) else { return }

        var originalValue = cell.fullValue ?? cell.value
        if cell.needsFullValueLoad {
            await ensureFullValue(rowID: rowID, column: column)
            guard let refreshed = gridRows.first(where: { $0.id == rowID })?.cells[column],
                  !refreshed.needsFullValueLoad else {
                // 第二次加载没成功：不把截断值写进暂存。
                return
            }
            originalValue = refreshed.fullValue ?? refreshed.value
        }

        let outcome = pendingStore.apply(.editCell(
            row: identity,
            column: column,
            value: value,
            originalValue: originalValue
        ))
        handleEditOutcome(outcome)
    }

    /// `∅`：把字段设为 NULL（走与手工编辑相同的路径）。
    public func setInspectorNull(rowID: String, column: String) async {
        await applyInspectorEdit(rowID: rowID, column: column, value: .null)
    }

    private func handleEditOutcome(_ outcome: PendingOperationOutcome) {
        if case .rejected(let error) = outcome {
            showToast(error.message)
            return
        }
        rebuildPendingPresentation()
        syncPendingFlag()
        bumpRevision()
    }

    // MARK: 行操作

    /// `＋ 插入行` / `⌘I`：新建一个空的新增行。
    public func beginInsert() {
        guard isEditingEnabled else { return }
        let id = UUID()
        pendingStore.apply(.beginInsertion(id: id))
        rebuildPendingPresentation()
        syncPendingFlag()
        bumpRevision()
        focusRow(rowID: Self.insertionRowID(id), column: firstEditableColumnName)
    }

    /// `⌘D` / 右键「复制行」：复制选中行为新增行；自增主键与生成列留空。
    ///
    /// 复制前会把未加载的大字段加载完整，避免把截断值复制进新行（L27 / 08 §9）。
    public func copySelectedRows(rowIDs: [String]) async {
        guard isEditingEnabled, !rowIDs.isEmpty else { return }
        var firstInsertionID: String?
        for rowID in rowIDs {
            guard let row = gridRows.first(where: { $0.id == rowID }), !isInsertionRow(rowID: rowID) else { continue }
            guard row.changeKind != .deletion else { continue }
            guard rowIdentity(for: row) != nil else { continue }

            for column in columns where row.cells[column.name]?.needsFullValueLoad == true {
                await ensureFullValue(rowID: rowID, column: column.name)
            }
            guard let refreshed = gridRows.first(where: { $0.id == rowID }) else { continue }

            let newID = UUID()
            pendingStore.apply(.beginInsertion(id: newID))
            if firstInsertionID == nil { firstInsertionID = Self.insertionRowID(newID) }
            for column in columns {
                if column.isAutoIncrement || column.isGenerated == true { continue }
                guard let cell = refreshed.cells[column.name] else { continue }
                // 用完整值 / 首屏值；NULL 原样复制。
                pendingStore.apply(.editCell(
                    row: .insertion(newID),
                    column: column.name,
                    value: cell.displayValue,
                    originalValue: .null
                ))
            }
        }
        rebuildPendingPresentation()
        syncPendingFlag()
        bumpRevision()
        if let firstInsertionID {
            focusRow(rowID: firstInsertionID, column: firstEditableColumnName)
        }
    }

    /// `⌫` / 右键「删除行」：先展示将执行的 `WHERE` 条件让用户确认（`specs/04-data-editing.md` §6）。
    ///
    /// 只选中新增行时没有 `WHERE`，直接取消整行，不弹确认。
    public func deleteRows(rowIDs: [String]) {
        guard isEditingEnabled, !rowIDs.isEmpty else { return }
        var deletable: [String] = []
        var conditions: [String] = []
        for rowID in rowIDs {
            guard let row = gridRows.first(where: { $0.id == rowID }) else { continue }
            guard row.changeKind != .deletion else { continue }
            guard let identity = rowIdentity(for: row) else { continue }
            deletable.append(rowID)
            if let locator = identity.locator, let clause = deletionClause(for: locator) {
                conditions.append("WHERE \(clause)")
            }
        }
        guard !deletable.isEmpty else { return }
        if conditions.isEmpty {
            performDelete(rowIDs: deletable)
        } else {
            pendingDeletion = PendingRowDeletion(rowIDs: deletable, conditions: conditions)
            bumpRevision()
        }
    }

    /// 确认删除：把待删除的行标记进暂存。
    public func confirmDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        performDelete(rowIDs: pending.rowIDs)
    }

    /// 取消删除：不产生任何暂存改动。
    public func cancelDeletion() {
        guard pendingDeletion != nil else { return }
        pendingDeletion = nil
        bumpRevision()
    }

    /// 用行的冻结定位键生成 `WHERE` 子句（不含 `WHERE` 前缀）。
    private func deletionClause(for locator: RowLocator) -> String? {
        try? PendingChangeSQL.locationClause(
            locator,
            introducer: session.mysql.charsetIntroducer,
            escaper: session.mysql.makeEscaper()
        )
    }

    private func performDelete(rowIDs: [String]) {
        var changed = false
        for rowID in rowIDs {
            guard let row = gridRows.first(where: { $0.id == rowID }) else { continue }
            guard row.changeKind != .deletion else { continue }
            guard let identity = rowIdentity(for: row) else { continue }
            pendingStore.apply(.deleteRow(identity))
            changed = true
        }
        guard changed else { return }
        rebuildPendingPresentation()
        syncPendingFlag()
        bumpRevision()
    }

    /// 右键「撤销该行的修改」：只回退这一行（`specs/04-data-editing.md` §8）。
    public func undoRow(rowID: String) {
        guard let row = gridRows.first(where: { $0.id == rowID }), let identity = rowIdentity(for: row) else { return }
        pendingStore.apply(.undoRow(identity))
        rebuildPendingPresentation()
        syncPendingFlag()
        bumpRevision()
    }

    /// 字段栏「撤销删除」。
    public func undoDeletion(rowID: String) {
        undoRow(rowID: rowID)
    }

    // MARK: 放弃

    public func requestDiscard() {
        guard !pendingStore.isEmpty else { return }
        if needsDiscardConfirmation {
            isDiscardConfirmationPresented = true
        } else {
            Task { await discardChanges() }
        }
    }

    public func cancelDiscardConfirmation() {
        isDiscardConfirmationPresented = false
    }

    /// 清空暂存并重新加载当前页（`specs/04-data-editing.md` §11）。
    public func discardChanges() async {
        isDiscardConfirmationPresented = false
        guard !pendingStore.isEmpty else { return }
        pendingStore.apply(.discardAll)
        rebuildPendingPresentation()
        syncPendingFlag()
        bumpRevision()
        await reloadCurrentPage()
    }

    // MARK: 预览

    /// `⇧⌘P`：生成并展示将执行的 SQL（与提交同一条生成路径）。
    public func presentPreview() {
        guard !pendingStore.isEmpty else { return }
        do {
            previewStatements = try makeStatements()
            isPreviewPresented = true
        } catch {
            showToast("生成预览 SQL 失败：\(Self.errorText(error))")
        }
    }

    public func dismissPreview() {
        isPreviewPresented = false
    }

    /// 预览里的「在新查询标签中打开」：放进一个查询标签，之后不再走暂存（`specs/04-data-editing.md` §9）。
    public func openPreviewInQueryTab() {
        guard !previewStatements.isEmpty else { return }
        isPreviewPresented = false
        session.newQueryTab(initialSQL: previewStatements.joined(separator: "\n"))
    }

    /// 请求呈现快速查看（字段栏 BLOB 「查看」等入口）。
    public func requestQuickLook(rowID: String, column: String) {
        guard let content = quickLookContent(rowID: rowID, column: column) else { return }
        quickLookRequest = content
        if content.isLoading {
            Task { [weak self] in
                await self?.ensureFullValue(rowID: rowID, column: column)
                guard let updated = self?.quickLookContent(rowID: rowID, column: column) else { return }
                self?.quickLookRequest = updated
            }
        }
    }

    /// 快速查看已经弹出后清掉请求，避免同一内容重复触发。
    public func clearQuickLookRequest() {
        quickLookRequest = nil
    }

    public var previewSQLText: String {
        previewStatements.enumerated()
            .map { "\($0.offset + 1)\t\($0.element)" }
            .joined(separator: "\n")
    }

    /// 预览 / 提交共用的语句生成入口。
    public func makeStatements() throws -> [String] {
        try PendingChangeSQL.statements(
            for: pendingStore,
            database: database,
            table: table,
            columns: columns,
            introducer: session.mysql.charsetIntroducer,
            escaper: session.mysql.makeEscaper()
        )
    }

    // MARK: 提交

    public func requestSubmit() {
        guard !isCommitting else { return }
        Task { _ = await submitChanges() }
    }

    /// `⌘↩` / 菜单「提交修改」：在一个事务里逐条下发，全部成功才清暂存。
    ///
    /// 硬约束（`docs/tech-designs/08-pending-changes.md` §5）：
    /// - 只读连接拒绝；暂存为空无操作；
    /// - 重定位校验 → 事务内逐条执行 → 任一条失败立即 `ROLLBACK` 且**保留暂存**；
    /// - 变更语句只允许 INSERT / UPDATE / DELETE。
    @discardableResult
    public func submitChanges() async -> Bool {
        guard !pendingStore.isEmpty else { return true }
        guard !isCommitting else { return false }
        guard isEditable else {
            showToast(editability.reason?.message ?? "当前表不可编辑")
            return false
        }
        do {
            try pendingStore.validateLocators()
        } catch {
            showToast((error as? PendingChangeValidationError)?.message ?? "行定位校验失败")
            return false
        }

        let statements: [String]
        do {
            statements = try makeStatements()
        } catch {
            showToast("生成提交 SQL 失败：\(Self.errorText(error))")
            return false
        }
        guard statements.allSatisfy(Self.isDataModificationStatement) else {
            showToast("暂存区包含非 INSERT / UPDATE / DELETE 语句，请改用 SQL 编辑器执行")
            return false
        }

        isCommitting = true
        commitCompleted = 0
        commitTotal = statements.count
        commitFailure = nil
        cancelCommitRequested = false
        bumpRevision()

        let started = clock.now
        let succeeded = await runTransaction(statements)
        isCommitting = false
        cancelCommitRequested = false

        if succeeded {
            let count = pendingStore.totalCount
            pendingStore.apply(.discardAll)
            rebuildPendingPresentation()
            syncPendingFlag()
            bumpRevision()
            await reloadCurrentPage()
            let milliseconds = max(0, Int(clock.now.timeIntervalSince(started) * 1000))
            showToast("已提交 \(count) 处修改 · \(milliseconds) ms")
            return true
        }

        bumpRevision()
        return false
    }

    /// 提交过程中取消（在两条语句之间回滚，`docs/tech-designs/08-pending-changes.md` §5）。
    public func cancelCommit() {
        guard isCommitting else { return }
        cancelCommitRequested = true
        Task { try? await session.cancelCurrentQuery() }
    }

    public func dismissCommitFailure() {
        commitFailure = nil
        bumpRevision()
    }

    private func runTransaction(_ statements: [String]) async -> Bool {
        do {
            try await runStatement("BEGIN")
        } catch {
            commitFailure = Self.failure(
                index: 1,
                statement: "BEGIN",
                error: error,
                count: statements.count,
                unknownState: true
            )
            return false
        }

        for (offset, statement) in statements.enumerated() {
            if cancelCommitRequested {
                await rollback()
                commitFailure = CommitFailure(
                    index: offset + 1,
                    statement: statement,
                    message: "提交已取消",
                    isCancelled: true
                )
                return false
            }
            do {
                try await runStatement(statement)
                commitCompleted = offset + 1
                bumpRevision()
            } catch {
                await rollback()
                commitFailure = Self.failure(
                    index: offset + 1,
                    statement: statement,
                    error: error,
                    count: statements.count
                )
                return false
            }
        }

        do {
            try await runStatement("COMMIT")
            return true
        } catch {
            commitFailure = Self.failure(
                index: statements.count,
                statement: "COMMIT",
                error: error,
                count: statements.count,
                unknownState: true
            )
            return false
        }
    }

    /// 执行一条事务语句。
    ///
    /// **关键**：`ConnectionSession.execute` 对语句级错误不抛异常，而是放在
    /// `result.firstError` 里（`03-mysql-layer.md` §3），所以这里必须显式检查，
    /// 否则唯一键冲突会被当成提交成功。
    private func runStatement(_ sql: String) async throws {
        let result = try await session.execute(sql, database: database, recordHistory: false)
        if let error = result.firstError {
            throw error
        }
    }

    /// 尽力回滚；回滚本身失败不覆盖原始错误。
    private func rollback() async {
        _ = try? await session.execute("ROLLBACK", database: database, recordHistory: false)
    }

    static func failure(
        index: Int,
        statement: String,
        error: Error,
        count: Int,
        unknownState: Bool = false
    ) -> CommitFailure {
        if let mysqlError = error as? MySQLError {
            return CommitFailure(
                index: index,
                statement: statement,
                code: mysqlError.code,
                sqlState: mysqlError.sqlState,
                message: mysqlError.message,
                explanation: mysqlError.chineseExplanation,
                isCancelled: mysqlError.isCancellation,
                isUnknownTransactionState: unknownState || mysqlError.kind == .timeout
            )
        }
        return CommitFailure(
            index: index,
            statement: statement,
            message: String(describing: error),
            explanation: "发生未知错误。",
            isUnknownTransactionState: unknownState
        )
    }

    static func isDataModificationStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.hasPrefix("INSERT") || trimmed.hasPrefix("UPDATE") || trimmed.hasPrefix("DELETE")
    }

    // MARK: 焦点

    /// 双击单元格：切到字段栏并聚焦对应字段。
    public func focusInspector(rowID: String, column: String) {
        guard gridRows.contains(where: { $0.id == rowID }) else { return }
        selectedRowIDs = [rowID]
        focusedRowID = rowID
        focusedColumn = column
        if !preferences.showInspector { preferences.showInspector = true }
        focusRequestColumn = column
        focusRequestToken &+= 1
        requestFullRowLoad(force: false)
    }

    private func focusRow(rowID: String, column: String?) {
        selectedRowIDs = [rowID]
        focusedRowID = rowID
        focusedColumn = column
        if !preferences.showInspector { preferences.showInspector = true }
        focusRequestColumn = column
        focusRequestToken &+= 1
    }

    private var firstEditableColumnName: String? {
        columns.first { FieldEditorResolver.kind(for: $0, tinyintAsCheckbox: preferences.tinyintAsCheckbox) != .binary }?.name
            ?? columns.first?.name
    }

    // MARK: 投影维护

    /// 由暂存区重建网格的行状态与单元格编辑中值。
    ///
    /// 这是唯一的投影出口：暂存区是唯一真源，网格 / 字段栏都从这里派生。
    internal func rebuildPendingPresentation() {
        for index in rows.indices {
            rows[index].changeKind = nil
            for (column, var cell) in rows[index].cells {
                cell.draftValue = nil
                rows[index].cells[column] = cell
            }
        }

        var insertions: [GridRow] = []
        for change in pendingStore.changes {
            switch change {
            case .update(let locator, let edits):
                guard let index = rows.firstIndex(where: { $0.locator == locator }) else { continue }
                rows[index].changeKind = .update
                for edit in edits { rows[index].cells[edit.column]?.draftValue = edit.value }

            case .deletion(let locator):
                guard let index = rows.firstIndex(where: { $0.locator == locator }) else { continue }
                rows[index].changeKind = .deletion

            case .insertion(let id, let edits):
                var row = makeInsertionRow(id: id)
                for edit in edits { row.cells[edit.column]?.draftValue = edit.value }
                insertions.append(row)
            }
        }
        insertionRows = insertions
    }

    private func makeInsertionRow(id: UUID) -> GridRow {
        var cells: [String: GridCell] = [:]
        for column in columns {
            cells[column.name] = GridCell(value: .text(""))
        }
        return GridRow(
            id: Self.insertionRowID(id),
            rowIndexInPage: -1,
            locator: nil,
            cells: cells,
            changeKind: .insertion
        )
    }

    private func rowIdentity(for row: GridRow) -> RowIdentity? {
        if isInsertionRow(rowID: row.id) {
            let uuidString = String(row.id.dropFirst(Self.insertionRowPrefix.count))
            guard let uuid = UUID(uuidString: uuidString) else { return nil }
            return .insertion(uuid)
        }
        if let locator = row.locator { return .existing(locator) }
        return nil
    }

    internal func syncPendingFlag() {
        tab.hasPendingChanges = !pendingStore.isEmpty
    }
}
