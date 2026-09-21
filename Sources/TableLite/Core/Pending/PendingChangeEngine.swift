import Foundation

// MARK: - 变更暂存引擎
//
// 纯逻辑：合并规则 + SQL 生成。值语义、无 IO、可单元测试。
// 见 docs/tech-designs/08-pending-changes.md §2.2 §3 与 specs/04-data-editing.md §8。
//
// 关键决策（docs/tech-designs/08-pending-changes.md §2.1）：
// 行定位键在**第一次编辑该行时被冻结**，后续再改这一行（包括主键列）都不会改变它；
// 因此 WHERE 永远匹配修改前的值。

/// 暂存区操作被拒绝的原因。
enum PendingChangeError: Error, Hashable, Sendable {
    /// 对已删除行编辑 → 提示先撤销删除
    case rowAlreadyDeleted
    /// 表不可编辑（无主键 / 视图）
    case notEditable(String)
    /// 行定位键为空，无法安全定位
    case primaryKeyMissing
}

/// 变更暂存的核心逻辑。
///
/// 同一行最多只有一条 pending change（新增 / 修改 / 删除三选一）。
/// 合并规则见 docs/tech-designs/08-pending-changes.md §2.2。
struct PendingChangeEngine {

    let table: TableRef
    let structure: TableStructure
    private(set) var changes: [PendingRowChange]

    init(table: TableRef, structure: TableStructure, changes: [PendingRowChange] = []) {
        self.table = table
        self.structure = structure
        self.changes = changes
    }

    // MARK: - 查询

    var isEmpty: Bool { changes.isEmpty }

    var stats: PendingChangeStats {
        var summary = PendingChangeStats()
        for change in changes {
            switch change.kind {
            case .insert: summary.inserts += 1
            case .update: summary.updates += 1
            case .delete: summary.deletes += 1
            }
        }
        return summary
    }

    func change(for row: RowIdentity) -> PendingRowChange? {
        changes.first { $0.identity == row }
    }

    // MARK: - 新增

    /// 开始一条新增行，返回它的 identity（调用方拿去在网格里占位）。
    mutating func beginInsert() -> RowIdentity {
        let identity = RowIdentity.inserted()
        changes.append(PendingRowChange(
            identity: identity,
            kind: .insert,
            table: table,
            locator: nil,
            baseValues: [:],
            values: [:]
        ))
        return identity
    }

    /// 新增行里填一个字段。只有真正填过的列才进入 INSERT。
    mutating func setInsertValue(row: RowIdentity, column: String, value: CellValue) {
        guard let index = changes.firstIndex(where: { $0.identity == row }),
              changes[index].kind == .insert else { return }
        changes[index].values[column] = value
    }

    /// 取消一条新增行（不产生任何 SQL）。
    mutating func cancelInsert(row: RowIdentity) {
        guard let index = changes.firstIndex(where: { $0.identity == row }),
              changes[index].kind == .insert else { return }
        changes.remove(at: index)
    }

    // MARK: - 修改

    /// 字段栏提交一次编辑。
    ///
    /// - `locator`：第一次编辑该行时冻结的行定位键（通常是全部主键列）；
    /// - `originalValue`：该列在数据库里的原值（首次编辑时用于冻结 `baseValues`）。
    mutating func applyEdit(
        row: RowIdentity,
        locator: RowLocator,
        column: String,
        originalValue: CellValue,
        newValue: CellValue
    ) throws {
        if let index = changes.firstIndex(where: { $0.identity == row }) {
            let existing = changes[index]
            switch existing.kind {
            case .delete:
                // 删除行不可编辑，先撤销删除
                throw PendingChangeError.rowAlreadyDeleted

            case .insert:
                // 合并进新增
                var updated = existing
                updated.values[column] = newValue
                changes[index] = updated
                return

            case .update:
                var updated = existing
                // 冻结基准值：后续编辑都拿它判断「改回原值」
                let base = updated.baseValues[column] ?? originalValue
                if newValue == base {
                    updated.values[column] = nil
                    if updated.values.isEmpty {
                        changes.remove(at: index)
                    } else {
                        changes[index] = updated
                    }
                } else {
                    updated.baseValues[column] = base
                    updated.values[column] = newValue
                    changes[index] = updated
                }
                return
            }
        }

        guard structure.isEditableStructure else {
            throw PendingChangeError.notEditable(notEditableMessage)
        }
        guard !locator.isEmpty else {
            throw PendingChangeError.primaryKeyMissing
        }
        // 值没变 → 不记录，行保持干净
        guard newValue != originalValue else { return }

        changes.append(PendingRowChange(
            identity: row,
            kind: .update,
            table: table,
            locator: locator,
            baseValues: [column: originalValue],
            values: [column: newValue]
        ))
    }

    // MARK: - 删除

    mutating func applyDelete(row: RowIdentity, locator: RowLocator) {
        if let index = changes.firstIndex(where: { $0.identity == row }) {
            let existing = changes[index]
            switch existing.kind {
            case .insert:
                // 新增行再删除 → 两者都消失，不产生任何 SQL
                changes.remove(at: index)
                return
            case .delete:
                return
            case .update:
                // 修改被删除取代；沿用冻结的定位键（可能主键已被改过）
                changes[index] = PendingRowChange(
                    identity: row,
                    kind: .delete,
                    table: table,
                    locator: existing.locator ?? locator,
                    baseValues: existing.baseValues,
                    values: [:]
                )
                return
            }
        }

        // 防御：不可编辑的表 / 空定位键不记录删除，避免生成无 WHERE 的语句
        guard structure.isEditableStructure, !locator.isEmpty else { return }
        changes.append(PendingRowChange(
            identity: row,
            kind: .delete,
            table: table,
            locator: locator,
            baseValues: [:],
            values: [:]
        ))
    }

    // MARK: - 撤销

    /// 撤销某一行的改动（只回退该行）。
    mutating func undo(row: RowIdentity) {
        changes.removeAll { $0.identity == row }
    }

    /// 清空整个暂存区。
    mutating func discardAll() {
        changes.removeAll()
    }

    // MARK: - SQL 生成

    /// 生成将要执行的语句。Preview 与 Commit 共用同一份，见 docs/08 §3。
    ///
    /// 顺序固定为 INSERT → UPDATE → DELETE；同类型内按用户操作顺序。
    func sqlStatements(using literalizer: SQLValueLiteralizer) -> [PendingSQLStatement] {
        var statements: [PendingSQLStatement] = []
        for kind in [PendingRowChange.Kind.insert, .update, .delete] {
            for change in changes where change.kind == kind {
                guard let text = makeSQL(for: change, using: literalizer) else { continue }
                statements.append(PendingSQLStatement(
                    id: statements.count + 1,
                    text: text,
                    kind: change.kind,
                    identity: change.identity
                ))
            }
        }
        return statements
    }

    // MARK: - 内部

    private var qualifiedTable: String {
        SQLIdentifier.qualified(table.database, table.table)
    }

    private var notEditableMessage: String {
        structure.kind == .view ? "视图不可编辑" : "该表没有主键，无法安全定位行"
    }

    private func makeSQL(for change: PendingRowChange, using literalizer: SQLValueLiteralizer) -> String? {
        switch change.kind {
        case .insert:
            return insertSQL(change, using: literalizer)

        case .update:
            guard let locator = change.locator,
                  let whereClause = whereClause(locator, using: literalizer) else { return nil }
            // SET 按列在表中的顺序输出，保证确定性
            let assignments = structure.columns.compactMap { column -> String? in
                guard let value = change.values[column.name] else { return nil }
                let literal = SQLValueLiteral.literal(value, kind: column.kind, using: literalizer)
                return "\(SQLIdentifier.quote(column.name)) = \(literal)"
            }
            guard !assignments.isEmpty else { return nil }
            return "UPDATE \(qualifiedTable) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause)"

        case .delete:
            guard let locator = change.locator,
                  let whereClause = whereClause(locator, using: literalizer) else { return nil }
            return "DELETE FROM \(qualifiedTable) WHERE \(whereClause)"
        }
    }

    private func insertSQL(_ change: PendingRowChange, using literalizer: SQLValueLiteralizer) -> String {
        // 只包含用户实际填过的列；一列都没填 → () VALUES ()，交给服务器默认值
        let columns = structure.columns.filter { change.values[$0.name] != nil }
        guard !columns.isEmpty else {
            return "INSERT INTO \(qualifiedTable) () VALUES ()"
        }
        let names = SQLIdentifier.list(columns.map(\.name))
        let literals = columns.map { column in
            SQLValueLiteral.literal(change.values[column.name]!, kind: column.kind, using: literalizer)
        }
        return "INSERT INTO \(qualifiedTable) (\(names)) VALUES (\(literals.joined(separator: ", ")))"
    }

    /// WHERE 用全部行定位键、`AND` 连接；NULL 用 `IS NULL`。见 docs/08 §3。
    private func whereClause(_ locator: RowLocator, using literalizer: SQLValueLiteralizer) -> String? {
        guard !locator.columns.isEmpty, locator.columns.count == locator.values.count else {
            return nil
        }
        let clauses = zip(locator.columns, locator.values).map { column, value -> String in
            let quoted = SQLIdentifier.quote(column)
            if value.isNull {
                return "\(quoted) IS NULL"
            }
            return "\(quoted) = \(SQLValueLiteral.literal(value, kind: kind(for: column), using: literalizer))"
        }
        return clauses.joined(separator: " AND ")
    }

    private func kind(for column: String) -> ColumnKind {
        structure.columns.first { $0.name == column }?.kind ?? .text
    }
}
