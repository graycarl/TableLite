import Combine
import Foundation

// MARK: - 变更暂存 Store
//
// `PendingChangeEngine` 的 `@MainActor` 包装：UI 直接调用，每次改动后触发 `objectWillChange`。
// 合并规则与 SQL 生成全在纯逻辑引擎里（见 docs/tech-designs/08-pending-changes.md §2.2 §3）。
@MainActor
final class PendingChangeStore: ObservableObject {

    /// 工具栏 / 状态栏的改动分类统计（@Published，供 SwiftUI 观察）。
    @Published private(set) var stats: PendingChangeStats

    private var engine: PendingChangeEngine

    init(table: TableRef, structure: TableStructure) {
        let engine = PendingChangeEngine(table: table, structure: structure)
        self.engine = engine
        self.stats = engine.stats
    }

    var changes: [PendingRowChange] { engine.changes }
    var isEmpty: Bool { engine.isEmpty }

    func change(for row: RowIdentity) -> PendingRowChange? {
        engine.change(for: row)
    }

    func isDirty(_ row: RowIdentity) -> Bool {
        engine.change(for: row) != nil
    }

    // MARK: 新增

    @discardableResult
    func beginInsert() -> RowIdentity {
        let identity = engine.beginInsert()
        sync()
        return identity
    }

    func setInsertValue(row: RowIdentity, column: String, value: CellValue) {
        engine.setInsertValue(row: row, column: column, value: value)
        sync()
    }

    func cancelInsert(row: RowIdentity) {
        engine.cancelInsert(row: row)
        sync()
    }

    // MARK: 修改 / 删除

    func applyEdit(
        row: RowIdentity,
        locator: RowLocator,
        column: String,
        originalValue: CellValue,
        newValue: CellValue
    ) throws {
        try engine.applyEdit(
            row: row,
            locator: locator,
            column: column,
            originalValue: originalValue,
            newValue: newValue
        )
        sync()
    }

    func applyDelete(row: RowIdentity, locator: RowLocator) {
        engine.applyDelete(row: row, locator: locator)
        sync()
    }

    // MARK: 撤销

    func undo(row: RowIdentity) {
        engine.undo(row: row)
        sync()
    }

    func discardAll() {
        engine.discardAll()
        sync()
    }

    // MARK: 预览 / 提交

    func sqlStatements(using literalizer: SQLValueLiteralizer) -> [PendingSQLStatement] {
        engine.sqlStatements(using: literalizer)
    }

    /// 用于「改回原值」判断：返回该行该列的冻结基准值，没有则回退到调用方给的值。
    func originalValue(row: RowIdentity, column: String, fallback: CellValue) -> CellValue {
        guard let change = engine.change(for: row),
              let base = change.baseValues[column] else { return fallback }
        return base
    }

    // MARK: 内部

    /// 每次改动后同步统计；即使数值不变也会赋值，从而触发 `objectWillChange`。
    private func sync() {
        stats = engine.stats
    }
}
