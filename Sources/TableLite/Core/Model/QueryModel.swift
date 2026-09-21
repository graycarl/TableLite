import Foundation

// MARK: - 查询结果

/// 一次下发产生的某个结果集的开头信息。
struct ResultSetHeader: Hashable, Sendable {
    var index: Int
    var columns: [ResultSetColumn]
    /// 没有结果集（OK 包）时的影响行数
    var affectedRows: UInt64
    var lastInsertID: UInt64

    var isResultSet: Bool { !columns.isEmpty }
}

/// `MySQLSession.query` 逐事件产出的内容。见 docs/tech-designs/03-mysql-layer.md §3。
enum QueryEvent: Sendable {
    case resultSet(ResultSetHeader)
    case row(resultIndex: Int, rowIndex: Int, values: [CellValue])
    case statementError(resultIndex: Int, error: MySQLServerError)
    case finished
}

/// 一次性读全的结果集（分页查询、元数据查询用）。
struct MaterializedResultSet: Sendable {
    var header: ResultSetHeader
    var rows: [[CellValue]]
}

// MARK: - 表 / 视图标识

struct TableRef: Hashable, Sendable {
    var database: String
    var table: String

    var displayName: String { "\(database).\(table)" }
}

enum DatabaseObjectKind: String, Hashable, Sendable, Codable {
    case table
    case view

    var displayName: String {
        switch self {
        case .table: return "表"
        case .view: return "视图"
        }
    }
}

struct DatabaseObject: Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(name)" }
    var name: String
    var kind: DatabaseObjectKind
    var rowEstimate: UInt64?
    var comment: String?
}

// MARK: - 表结构

struct TableIndex: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    /// PRIMARY / UNIQUE / FULLTEXT / SPATIAL / INDEX
    var indexType: String
    var columns: [IndexColumn]
    var cardinality: UInt64?
    var comment: String?

    var displayType: String {
        switch indexType.uppercased() {
        case "PRIMARY": return "PRIMARY"
        case "UNIQUE": return "UNIQUE"
        case "FULLTEXT": return "全文"
        case "SPATIAL": return "空间"
        default: return "普通"
        }
    }
}

struct IndexColumn: Hashable, Sendable {
    var name: String
    var descending: Bool
}

struct ForeignKeyConstraint: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var columns: [String]
    var referencedDatabase: String
    var referencedTable: String
    var referencedColumns: [String]
    var onDelete: String
    var onUpdate: String

    var referencedDisplay: String { "\(referencedDatabase).\(referencedTable)" }
}

struct TableTrigger: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    /// BEFORE / AFTER
    var timing: String
    /// INSERT / UPDATE / DELETE
    var event: String
    var statement: String
}

struct TableStructure: Hashable, Sendable {
    var ref: TableRef
    var kind: DatabaseObjectKind
    var comment: String?
    var columns: [TableColumn]
    var indexes: [TableIndex]
    var foreignKeys: [ForeignKeyConstraint]
    var triggers: [TableTrigger]
    var createStatement: String

    /// 主键列（按主键顺序）
    var primaryKeyColumns: [TableColumn] {
        columns.filter(\.isPrimaryKey)
    }

    /// 没有主键 → 整表只读。见 docs/tech-designs/08-pending-changes.md §7。
    var isEditableStructure: Bool {
        kind == .table && !primaryKeyColumns.isEmpty
    }
}

/// 表可编辑性的界面原因。见 specs/04-data-editing.md §2。
enum EditabilityReason: Hashable, Sendable {
    case editable
    case noPrimaryKey
    case view
    case readOnlyConnection

    var message: String? {
        switch self {
        case .editable: return nil
        case .noPrimaryKey: return "该表没有主键，无法安全定位行"
        case .view: return "视图不可编辑"
        case .readOnlyConnection: return "该连接处于只读模式"
        }
    }

    var isEditable: Bool { self == .editable }
}
