import Foundation

// MARK: - 行定位

/// 行定位键里的一个键值对。值在**第一次编辑该行时冻结**，之后不再变化。
///
/// 见 `docs/tech-designs/08-pending-changes.md` §2.1。
public struct RowKeyValue: Sendable, Codable, Equatable, Hashable {
    public var column: String
    /// 修改前的原值。
    public var value: SQLValue
    public var fieldType: MySQLFieldType
    public var isBinary: Bool

    public init(column: String, value: SQLValue, fieldType: MySQLFieldType, isBinary: Bool = false) {
        self.column = column
        self.value = value
        self.fieldType = fieldType
        self.isBinary = isBinary
    }
}

/// 行定位键。主键列按表定义顺序排列；无主键的表不可编辑，不会有 locator。
public struct RowLocator: Sendable, Codable, Equatable, Hashable {
    public var keys: [RowKeyValue]

    public init(keys: [RowKeyValue]) {
        self.keys = keys
    }

    public var isEmpty: Bool { keys.isEmpty }

    /// Diffable 数据源用的行身份字符串。用长度前缀编码，保证不同组合不碰撞。
    public var identityString: String {
        keys.map { key in
            let column = key.column
            let value = key.value.identityText
            return "\(column.utf8.count):\(column):\(value.utf8.count):\(value)"
        }.joined(separator: ";")
    }
}

/// 一行在暂存区里的身份：已有行用主键定位，新增行用合成 id。
public enum RowIdentity: Sendable, Codable, Equatable, Hashable {
    case existing(RowLocator)
    case insertion(UUID)

    public var isInsertion: Bool {
        if case .insertion = self { return true }
        return false
    }

    public var locator: RowLocator? {
        if case .existing(let locator) = self { return locator }
        return nil
    }
}

// MARK: - 暂存变更

/// 一列的新值。
public struct PendingEdit: Sendable, Codable, Equatable, Hashable {
    public var column: String
    public var value: SQLValue

    public init(column: String, value: SQLValue) {
        self.column = column
        self.value = value
    }
}

/// 暂存区里的一条变更：新增 / 修改 / 删除三选一。
///
/// 合并规则见 `docs/tech-designs/08-pending-changes.md` §2.2。
public enum PendingChange: Sendable, Codable, Equatable {
    /// 新增行：`edits` 只包含用户实际填过的列；为空时由服务器默认值补齐。
    case insertion(id: UUID, edits: [PendingEdit])
    /// 修改行：`locator` 是冻结的原值定位键。
    case update(locator: RowLocator, edits: [PendingEdit])
    /// 删除行。
    case deletion(locator: RowLocator)

    public enum Kind: String, Sendable, Codable, CaseIterable, Hashable {
        case insert
        case update
        case delete

        public var displayName: String {
            switch self {
            case .insert: return "新增"
            case .update: return "修改"
            case .delete: return "删除"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .insertion: return .insert
        case .update: return .update
        case .deletion: return .delete
        }
    }

    public var edits: [PendingEdit] {
        switch self {
        case .insertion(_, let edits), .update(_, let edits): return edits
        case .deletion: return []
        }
    }

    public var locator: RowLocator? {
        switch self {
        case .insertion: return nil
        case .update(let locator, _), .deletion(let locator): return locator
        }
    }

    public var rowIdentity: RowIdentity {
        switch self {
        case .insertion(let id, _): return .insertion(id)
        case .update(let locator, _), .deletion(let locator): return .existing(locator)
        }
    }
}

// MARK: - 暂存操作

/// 对暂存区的一次操作。所有合并规则都在 `PendingChangeStore.apply(_:)` 里。
public enum PendingOperation: Sendable, Equatable {
    /// 编辑某个单元格。`originalValue` 是该列在服务器上的原值，用于判断「改回原值」。
    case editCell(row: RowIdentity, column: String, value: SQLValue, originalValue: SQLValue)
    /// 把新增行的某列恢复为「未填」（交给数据库默认值）。
    case clearInsertCell(row: RowIdentity, column: String)
    /// 标记删除一行。
    case deleteRow(RowIdentity)
    /// 新建一个空的新增行（对应「＋ 插入行」）。
    case beginInsertion(id: UUID)
    /// 撤销某一行的全部改动。
    case undoRow(RowIdentity)
    /// 放弃全部改动。
    case discardAll
}

/// `apply(_:)` 的结果。
public enum PendingOperationOutcome: Sendable, Equatable {
    case noChange
    case insertionCreated
    case created(PendingChange.Kind)
    case merged(PendingChange.Kind)
    case replacedByDelete
    case removed
    case rejected(PendingChangeError)
}

/// 暂存区操作被拒绝的原因。
public enum PendingChangeError: Error, Sendable, Equatable {
    /// 该行已标记删除，先撤销删除再编辑。
    case rowDeleted
    /// 找不到指定的新增行。
    case insertionNotFound

    /// 界面上显示的中文提示。
    public var message: String {
        switch self {
        case .rowDeleted: return "这一行已标记删除，请先撤销删除再编辑"
        case .insertionNotFound: return "找不到对应的新增行"
        }
    }
}

/// 暂存区统计。
public struct PendingChangeCounts: Sendable, Equatable {
    public var insert: Int = 0
    public var update: Int = 0
    public var delete: Int = 0
    public var total: Int { insert + update + delete }
}

// MARK: - 暂存区

/// 每个数据网格标签一个独立暂存区。
///
/// 这是一个**纯值类型**：不含并发、不含 IO，方便单测合并规则。UI 侧由 `@MainActor`
/// 的 ViewModel 持有并驱动。
public struct PendingChangeStore: Sendable, Equatable {
    /// 保持用户操作顺序；SQL 生成时再按 INSERT → UPDATE → DELETE 分组。
    public private(set) var changes: [PendingChange]

    public init(changes: [PendingChange] = []) {
        self.changes = changes
    }

    public var isEmpty: Bool { changes.isEmpty }

    public var counts: PendingChangeCounts {
        var counts = PendingChangeCounts()
        for change in changes {
            switch change.kind {
            case .insert: counts.insert += 1
            case .update: counts.update += 1
            case .delete: counts.delete += 1
            }
        }
        return counts
    }

    public var totalCount: Int { changes.count }

    /// 状态栏文案：`有 7 处未提交的修改（3 新增 · 2 修改 · 2 删除）`。
    public var statusText: String? {
        guard !isEmpty else { return nil }
        let counts = counts
        return "有 \(counts.total) 处未提交的修改（\(counts.insert) 新增 · \(counts.update) 修改 · \(counts.delete) 删除）"
    }

    /// 按行身份查变更。
    public func change(for row: RowIdentity) -> PendingChange? {
        changes.first { $0.rowIdentity == row }
    }

    /// 校验所有行定位键非空（提交前防元数据过期，见 08 §5 第 3 步）。
    public func validateLocators() throws {
        for change in changes {
            if let locator = change.locator, locator.isEmpty {
                throw PendingChangeValidationError.missingLocator(change.kind)
            }
        }
    }

    // MARK: 应用操作

    @discardableResult
    public mutating func apply(_ operation: PendingOperation) -> PendingOperationOutcome {
        switch operation {
        case .discardAll:
            guard !changes.isEmpty else { return .noChange }
            changes.removeAll()
            return .removed

        case .beginInsertion(let id):
            if let existing = change(for: .insertion(id)), case .insertion = existing {
                return .noChange
            }
            changes.append(.insertion(id: id, edits: []))
            return .insertionCreated

        case .editCell(let row, let column, let value, let originalValue):
            return applyEditCell(row: row, column: column, value: value, originalValue: originalValue)

        case .clearInsertCell(let row, let column):
            return applyClearInsertCell(row: row, column: column)

        case .deleteRow(let row):
            return applyDelete(row: row)

        case .undoRow(let row):
            guard let index = changes.firstIndex(where: { $0.rowIdentity == row }) else {
                return .noChange
            }
            changes.remove(at: index)
            return .removed
        }
    }

    private mutating func applyEditCell(
        row: RowIdentity,
        column: String,
        value: SQLValue,
        originalValue: SQLValue
    ) -> PendingOperationOutcome {
        if let index = changes.firstIndex(where: { $0.rowIdentity == row }) {
            switch changes[index] {
            case .deletion:
                // 已删除的行拒绝编辑，提示先撤销删除。
                return .rejected(.rowDeleted)

            case .insertion(let id, var edits):
                upsert(&edits, column: column, value: value)
                changes[index] = .insertion(id: id, edits: edits)
                return .merged(.insert)

            case .update(let locator, var edits):
                if value == originalValue {
                    edits.removeAll { $0.column == column }
                    if edits.isEmpty {
                        changes.remove(at: index)
                        return .removed
                    }
                    changes[index] = .update(locator: locator, edits: edits)
                    return .merged(.update)
                }
                upsert(&edits, column: column, value: value)
                changes[index] = .update(locator: locator, edits: edits)
                return .merged(.update)
            }
        }

        // 没有现成变更。
        switch row {
        case .insertion(let id):
            var edits: [PendingEdit] = []
            upsert(&edits, column: column, value: value)
            changes.append(.insertion(id: id, edits: edits))
            return .created(.insert)
        case .existing(let locator):
            guard value != originalValue else { return .noChange }
            changes.append(.update(locator: locator, edits: [PendingEdit(column: column, value: value)]))
            return .created(.update)
        }
    }

    private mutating func applyClearInsertCell(row: RowIdentity, column: String) -> PendingOperationOutcome {
        guard let index = changes.firstIndex(where: { $0.rowIdentity == row }) else {
            return .rejected(.insertionNotFound)
        }
        switch changes[index] {
        case .insertion(let id, var edits):
            edits.removeAll { $0.column == column }
            changes[index] = .insertion(id: id, edits: edits)
            return .merged(.insert)
        case .deletion:
            return .rejected(.rowDeleted)
        case .update:
            // 已有行的「未填」没有意义：回退原值请直接编辑该列。
            return .rejected(.insertionNotFound)
        }
    }

    private mutating func applyDelete(row: RowIdentity) -> PendingOperationOutcome {
        if let index = changes.firstIndex(where: { $0.rowIdentity == row }) {
            switch changes[index] {
            case .insertion:
                // 新增行又删除：两者都消失，不产生任何 SQL。
                changes.remove(at: index)
                return .removed
            case .update(let locator, _):
                changes[index] = .deletion(locator: locator)
                return .replacedByDelete
            case .deletion:
                return .noChange
            }
        }
        switch row {
        case .insertion:
            return .noChange
        case .existing(let locator):
            changes.append(.deletion(locator: locator))
            return .created(.delete)
        }
    }

    private func upsert(_ edits: inout [PendingEdit], column: String, value: SQLValue) {
        if let index = edits.firstIndex(where: { $0.column == column }) {
            edits[index] = PendingEdit(column: column, value: value)
        } else {
            edits.append(PendingEdit(column: column, value: value))
        }
    }
}

/// 提交前的行定位校验错误。
public enum PendingChangeValidationError: Error, Sendable, Equatable {
    case missingLocator(PendingChange.Kind)

    public var message: String {
        switch self {
        case .missingLocator(let kind):
            return "\(kind.displayName)行的定位键为空，表结构可能已变化，请刷新后重试"
        }
    }
}

// MARK: - 可编辑性判定

/// 表 / 连接是否可编辑的原因。文案对应 `specs/04-data-editing.md` §2。
public enum UneditableReason: String, Sendable, Codable, Equatable, CaseIterable {
    case noPrimaryKey
    case view
    case readOnlyConnection

    public var message: String {
        switch self {
        case .noPrimaryKey: return "该表没有主键，无法安全定位行"
        case .view: return "视图不可编辑"
        case .readOnlyConnection: return "该连接处于只读模式"
        }
    }
}

public enum Editability: Sendable, Equatable {
    case editable
    case readOnly(UneditableReason)

    public var isEditable: Bool {
        if case .editable = self { return true }
        return false
    }

    public var reason: UneditableReason? {
        if case .readOnly(let reason) = self { return reason }
        return nil
    }
}

/// 可编辑性判定：只看主键，唯一索引不算数（`08-pending-changes.md` §7）。
public enum EditabilityEvaluator {
    public static func evaluate(
        isView: Bool,
        hasPrimaryKey: Bool,
        isConnectionReadOnly: Bool
    ) -> Editability {
        if isView { return .readOnly(.view) }
        if isConnectionReadOnly { return .readOnly(.readOnlyConnection) }
        if !hasPrimaryKey { return .readOnly(.noPrimaryKey) }
        return .editable
    }

    public static func primaryKeyColumns(in columns: [ColumnInfo]) -> [ColumnInfo] {
        columns.filter(\.isPrimaryKey)
    }

    public static func hasPrimaryKey(in columns: [ColumnInfo]) -> Bool {
        columns.contains(where: \.isPrimaryKey)
    }
}
