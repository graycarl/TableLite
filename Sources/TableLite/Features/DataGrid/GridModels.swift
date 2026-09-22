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
    /// 建表语句（用于「复制表结构」；可能为 nil）。
    public var createStatement: String?

    public init(
        columns: [ColumnInfo],
        tableInfo: TableInfo? = nil,
        isView: Bool = false,
        primaryKeyColumns: [String] = [],
        foreignKeyColumns: Set<String> = [],
        createStatement: String? = nil
    ) {
        self.columns = columns
        self.tableInfo = tableInfo
        self.isView = isView
        self.primaryKeyColumns = primaryKeyColumns
        self.foreignKeyColumns = foreignKeyColumns
        self.createStatement = createStatement
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
