import Foundation

// MARK: - 单元格值模型

/// 网格里一个单元格的值状态。
///
/// 这是两阶段大字段加载（`docs/tech-designs/07-data-grid.md` §3.1）的载体：
/// - `value` 是首屏从服务器拿到的值（大字段可能只是 `LEFT(col, N)` 的截断前缀）；
/// - `fullValue` 是二次加载后的完整值；
/// - `draftValue` 是暂存区投影到单元格的编辑中值（T9）。
///
/// **硬约束**：`isTruncated == true` 且 `fullValue == nil` 时，`value` 绝不能写回数据库
/// （`docs/tech-designs/08-pending-changes.md` §9）。编辑器必须先加载完整值再允许编辑。
public struct GridCell: Sendable, Equatable {
    /// 首屏值。
    public var value: SQLValue
    /// 首屏值是否是截断投影。
    public var isTruncated: Bool
    /// 截断列的真实字节数（来自长度列 `OCTET_LENGTH`）；非截断列为 nil。
    public var totalByteCount: Int?
    /// 二次加载得到的完整值。
    public var fullValue: SQLValue?
    /// 编辑中的值；由暂存区重建（T9）。
    public var draftValue: SQLValue?

    public init(
        value: SQLValue,
        isTruncated: Bool = false,
        totalByteCount: Int? = nil,
        fullValue: SQLValue? = nil,
        draftValue: SQLValue? = nil
    ) {
        self.value = value
        self.isTruncated = isTruncated
        self.totalByteCount = totalByteCount
        self.fullValue = fullValue
        self.draftValue = draftValue
    }

    /// 展示用值：优先编辑中值 → 完整值 → 首屏值。
    public var displayValue: SQLValue {
        draftValue ?? fullValue ?? value
    }

    /// 是否有未提交的编辑。
    public var isEdited: Bool {
        guard let draftValue else { return false }
        return draftValue != (fullValue ?? value)
    }

    /// 是否已拿到完整值（或本就没有截断）。
    public var hasCompleteValue: Bool {
        !isTruncated || fullValue != nil
    }

    /// 是否可以发起二次加载：截断且尚未加载。
    public var needsFullValueLoad: Bool {
        isTruncated && fullValue == nil
    }
}

/// 行状态（新增 / 修改 / 删除），由暂存区派生（T9）。
public enum GridRowChangeKind: Sendable, Equatable {
    case insertion
    case update
    case deletion

    public var marker: String? {
        switch self {
        case .insertion: return "+"
        case .update: return "●"
        case .deletion: return "✕"
        }
    }
}

/// 网格里的一行。
public struct GridRow: Identifiable, Sendable, Equatable {
    /// Diffable / 选中恢复用的行身份。有主键时是定位键字符串，否则是页内合成 id。
    public let id: String
    /// 页内下标（0-based，不含用于探测下一页的那一行）。
    public let rowIndexInPage: Int
    /// 行定位键；无主键的表为 nil。
    public let locator: RowLocator?
    /// 列名 → 单元格。
    public var cells: [String: GridCell]
    /// 行状态：由暂存区重建时写入（T9）。
    public var changeKind: GridRowChangeKind?

    public init(
        id: String,
        rowIndexInPage: Int,
        locator: RowLocator?,
        cells: [String: GridCell],
        changeKind: GridRowChangeKind? = nil
    ) {
        self.id = id
        self.rowIndexInPage = rowIndexInPage
        self.locator = locator
        self.cells = cells
        self.changeKind = changeKind
    }

    public func cell(_ column: String) -> GridCell? { cells[column] }

    /// 行是否可定位（能二次加载大字段 / 将来可编辑）。
    public var isLocatable: Bool { !(locator?.isEmpty ?? true) }
}

// MARK: - 元数据来源

/// 表数据视图需要的元数据。
public struct TableDataMetadata: Sendable, Equatable {
    public var columns: [ColumnInfo]
    public var tableInfo: TableInfo?
    public var isView: Bool
    public var primaryKeyColumns: [String]
    /// 参与外键约束的列名集合（用于 `↗` 标记）。
    public var foreignKeyColumns: Set<String>
    /// 外键约束明细（用于 `↗` 跳转：被引用库 / 表 / 列）。
    public var foreignKeys: [ForeignKeyInfo]
    /// 建表语句（用于「复制表结构」；可能为 nil）。
    public var createStatement: String?

    public init(
        columns: [ColumnInfo],
        tableInfo: TableInfo? = nil,
        isView: Bool = false,
        primaryKeyColumns: [String] = [],
        foreignKeyColumns: Set<String> = [],
        foreignKeys: [ForeignKeyInfo] = [],
        createStatement: String? = nil
    ) {
        self.columns = columns
        self.tableInfo = tableInfo
        self.isView = isView
        self.primaryKeyColumns = primaryKeyColumns
        // `foreignKeyColumns` 是 `foreignKeys` 的派生视图；未显式给出时自动推导。
        self.foreignKeyColumns = foreignKeyColumns.isEmpty
            ? Set(foreignKeys.flatMap(\.columns))
            : foreignKeyColumns
        self.foreignKeys = foreignKeys
        self.createStatement = createStatement
    }
}

// MARK: - 外键跳转（`specs/03-data-browsing.md` §10）

/// 外键跳转目标里的一个定位键：被引用表的列名 + 已转义好的 SQL 字面量。
public struct ForeignKeyJumpKey: Sendable, Equatable {
    /// 被引用表的列名。
    public var column: String
    /// 用 `SQLValueLiteral` 生成的字面量（含引号 / `0x…` / 数字原样）。
    public var literal: String

    public init(column: String, literal: String) {
        self.column = column
        self.literal = literal
    }
}

/// 外键 `↗` 跳转目标：被引用表 + 定位条件。
public struct ForeignKeyJumpTarget: Sendable, Equatable {
    public var database: String
    public var table: String
    public var keys: [ForeignKeyJumpKey]

    public init(database: String, table: String, keys: [ForeignKeyJumpKey]) {
        self.database = database
        self.table = table
        self.keys = keys
    }

    /// `col1 = lit1 AND col2 = lit2`；形态与 `PendingChangeSQL.locationClause` 一致。
    public var whereClause: String {
        keys.map { "\(SQLIdentifier.quote($0.column)) = \($0.literal)" }.joined(separator: " AND ")
    }
}

/// 从行 + 列元数据推导外键跳转目标。纯函数，便于单测。
public enum ForeignKeyJumpResolver {

    /// 推导 `↗` 跳转目标；无法跳转时返回 nil。
    ///
    /// 返回 nil 的情形：
    /// - 单击的列不属于任何外键；
    /// - 外键列（复合外键的**任一**列）值为 `NULL`；
    /// - 本地列与引用列数量不一致，或引用列名缺失；
    /// - 本地列元数据缺失（无法判定类型 / 是否二进制）。
    ///
    /// 复合外键策略：一次点击解析外键的**全部**列，`whereClause` 用 `AND` 连接，
    /// 等价于 `WHERE (a, b) = (va, vb)`；任一列为 `NULL` 视为整条外键不成立。
    ///
    /// 字面量按本地外键列的元数据生成（外键约束要求两侧类型兼容），
    /// 且**只接受原始 `SQLValue`**——调用方不得传入截断后的展示文本
    /// （`docs/tech-designs/07-data-grid.md` §3.1）。
    public static func target(
        sourceDatabase: String,
        clickedColumn: String,
        columns: [ColumnInfo],
        values: [String: SQLValue],
        foreignKeys: [ForeignKeyInfo],
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil
    ) -> ForeignKeyJumpTarget? {
        guard let foreignKey = foreignKeys.first(where: { $0.columns.contains(clickedColumn) }),
              !foreignKey.columns.isEmpty,
              foreignKey.columns.count == foreignKey.referencedColumns.count,
              !foreignKey.referencedTable.isEmpty,
              foreignKey.referencedColumns.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        var keys: [ForeignKeyJumpKey] = []
        keys.reserveCapacity(foreignKey.columns.count)
        for (index, sourceColumn) in foreignKey.columns.enumerated() {
            guard let value = values[sourceColumn], !value.isNull,
                  let column = columns.first(where: { $0.name == sourceColumn }) else {
                return nil
            }
            let literal = SQLValueLiteral.literal(
                for: value,
                column: column,
                escaping: escaping,
                introducer: introducer
            )
            keys.append(ForeignKeyJumpKey(column: foreignKey.referencedColumns[index], literal: literal))
        }
        let database = (foreignKey.referencedDatabase?.isEmpty == false)
            ? foreignKey.referencedDatabase!
            : sourceDatabase
        return ForeignKeyJumpTarget(database: database, table: foreignKey.referencedTable, keys: keys)
    }
}

/// 列清单与行数估算的来源。生产实现走 `MetaRepository`，单测注入假实现。
///
/// 列清单来自 `information_schema.COLUMNS`（`07-data-grid.md` §3.2），
/// **不用** `SELECT * LIMIT 0`。
public protocol TableDataMetadataProviding: Sendable {
    func loadMetadata(database: String, table: String, forceRefresh: Bool) async throws -> TableDataMetadata
    func loadRowCountEstimate(database: String, table: String, forceRefresh: Bool) async throws -> RowCountEstimate?
}

/// 走 `MetaRepository` 的生产实现。
public struct LiveTableDataMetadataProvider: TableDataMetadataProviding {
    private let repository: MetaRepository

    public init(repository: MetaRepository) {
        self.repository = repository
    }

    public func loadMetadata(database: String, table: String, forceRefresh: Bool) async throws -> TableDataMetadata {
        let structure = try await repository.structure(
            database: database,
            table: table,
            kind: .table,
            forceRefresh: forceRefresh
        )
        return TableDataMetadata(
            columns: structure.columns,
            tableInfo: structure.table,
            isView: structure.table.kind == .view,
            primaryKeyColumns: structure.primaryKeyColumns.map(\.name),
            foreignKeyColumns: Set(structure.foreignKeys.flatMap(\.columns)),
            foreignKeys: structure.foreignKeys,
            createStatement: structure.createStatement
        )
    }

    public func loadRowCountEstimate(database: String, table: String, forceRefresh: Bool) async throws -> RowCountEstimate? {
        try await repository.rowCountEstimate(database: database, table: table, forceRefresh: forceRefresh)
    }
}

// MARK: - 加载状态

public enum TableDataLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

// MARK: - 快速查看请求

/// 快速查看面板要展示的内容快照。
public struct QuickLookContent: Sendable, Equatable {
    public var title: String
    public var columnName: String
    public var kind: QuickLookKind
    public var text: String
    public var data: Data?
    public var isNull: Bool
    public var isLoading: Bool
    public var error: String?
    public var byteCount: Int?

    public init(
        title: String,
        columnName: String,
        kind: QuickLookKind,
        text: String = "",
        data: Data? = nil,
        isNull: Bool = false,
        isLoading: Bool = false,
        error: String? = nil,
        byteCount: Int? = nil
    ) {
        self.title = title
        self.columnName = columnName
        self.kind = kind
        self.text = text
        self.data = data
        self.isNull = isNull
        self.isLoading = isLoading
        self.error = error
        self.byteCount = byteCount
    }
}
