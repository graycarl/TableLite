import Foundation

// MARK: - 表 / 视图

/// 对象类型。对象树只有表与视图两组。
public enum TableKind: String, Sendable, Codable, CaseIterable, Hashable {
    case table
    case view

    public var displayName: String {
        switch self {
        case .table: return "表"
        case .view: return "视图"
        }
    }
}

/// 对象树里的一个对象（表或视图）。
public struct SchemaObject: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var database: String
    public var name: String
    public var kind: TableKind
    public var id: String { "\(database).\(name)" }

    public init(database: String, name: String, kind: TableKind) {
        self.database = database
        self.name = name
        self.kind = kind
    }
}

/// 表信息。行数来自 `information_schema.TABLES` 的估算值，**绝不自动 `COUNT(*)`**。
///
/// 见 `docs/tech-designs/07-data-grid.md` §3.4、`11-schema-and-import-export.md` §1。
public struct TableInfo: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var database: String
    public var name: String
    public var kind: TableKind
    public var engine: String?
    /// `TABLE_ROWS` 估算值。
    public var rowCountEstimate: Int64?
    public var comment: String?
    public var collation: String?
    public var id: String { "\(database).\(name)" }

    public init(
        database: String,
        name: String,
        kind: TableKind = .table,
        engine: String? = nil,
        rowCountEstimate: Int64? = nil,
        comment: String? = nil,
        collation: String? = nil
    ) {
        self.database = database
        self.name = name
        self.kind = kind
        self.engine = engine
        self.rowCountEstimate = rowCountEstimate
        self.comment = comment
        self.collation = collation
    }
}

// MARK: - 索引

/// 索引类型。需求见 `specs/07-schema-view.md` §2.2。
public enum IndexKind: String, Sendable, Codable, CaseIterable, Hashable {
    case primary
    case unique
    case normal
    case fulltext
    case spatial

    public var displayName: String {
        switch self {
        case .primary: return "PRIMARY"
        case .unique: return "UNIQUE"
        case .normal: return "普通"
        case .fulltext: return "全文"
        case .spatial: return "空间"
        }
    }
}

/// 索引里的一列。
public struct IndexColumn: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var isDescending: Bool
    /// 前缀索引长度；非前缀索引为 nil。
    public var prefixLength: Int?

    public init(name: String, isDescending: Bool = false, prefixLength: Int? = nil) {
        self.name = name
        self.isDescending = isDescending
        self.prefixLength = prefixLength
    }
}

public struct IndexInfo: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var name: String
    public var kind: IndexKind
    public var columns: [IndexColumn]
    public var cardinality: Int64?
    public var comment: String?
    public var id: String { name }

    public init(
        name: String,
        kind: IndexKind,
        columns: [IndexColumn],
        cardinality: Int64? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.columns = columns
        self.cardinality = cardinality
        self.comment = comment
    }
}

// MARK: - 外键

public struct ForeignKeyInfo: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var name: String
    /// 本表列，按约束里的顺序。
    public var columns: [String]
    public var referencedDatabase: String?
    public var referencedTable: String
    public var referencedColumns: [String]
    /// 删除时动作：`CASCADE` / `SET NULL` / `RESTRICT` / `NO ACTION`。
    public var onDelete: String
    /// 更新时动作。
    public var onUpdate: String
    public var id: String { name }

    public init(
        name: String,
        columns: [String],
        referencedDatabase: String? = nil,
        referencedTable: String,
        referencedColumns: [String],
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        self.columns = columns
        self.referencedDatabase = referencedDatabase
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }

    /// `库.表` 形式的引用表名。
    public var referencedDisplayName: String {
        if let referencedDatabase, !referencedDatabase.isEmpty {
            return "\(referencedDatabase).\(referencedTable)"
        }
        return referencedTable
    }
}

// MARK: - 触发器

public enum TriggerTiming: String, Sendable, Codable, CaseIterable, Hashable {
    case before = "BEFORE"
    case after = "AFTER"
}

public enum TriggerEvent: String, Sendable, Codable, CaseIterable, Hashable {
    case insert = "INSERT"
    case update = "UPDATE"
    case delete = "DELETE"
}

public struct TriggerInfo: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var name: String
    public var timing: TriggerTiming
    public var event: TriggerEvent
    /// 触发器体，多行；界面折叠显示。
    public var statement: String
    public var id: String { name }

    public init(name: String, timing: TriggerTiming, event: TriggerEvent, statement: String) {
        self.name = name
        self.timing = timing
        self.event = event
        self.statement = statement
    }
}

// MARK: - 表结构

/// 表结构视图一次性需要的数据。视图只有列与定义两页。
///
/// 见 `specs/07-schema-view.md` §2、§3。
public struct TableStructure: Sendable, Codable, Equatable, Hashable {
    public var table: TableInfo
    public var columns: [ColumnInfo]
    public var indexes: [IndexInfo]
    public var foreignKeys: [ForeignKeyInfo]
    public var triggers: [TriggerInfo]
    /// 建表 / 建视图语句。
    public var createStatement: String?

    public init(
        table: TableInfo,
        columns: [ColumnInfo] = [],
        indexes: [IndexInfo] = [],
        foreignKeys: [ForeignKeyInfo] = [],
        triggers: [TriggerInfo] = [],
        createStatement: String? = nil
    ) {
        self.table = table
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.triggers = triggers
        self.createStatement = createStatement
    }

    /// 主键列（按表定义顺序）。
    public var primaryKeyColumns: [ColumnInfo] {
        columns.filter(\.isPrimaryKey)
    }

    /// 状态栏概况：`11 列 · 3 索引 · 1 外键 · 0 触发器`。
    public var summary: String {
        "\(columns.count) 列 · \(indexes.count) 索引 · \(foreignKeys.count) 外键 · \(triggers.count) 触发器"
    }
}
