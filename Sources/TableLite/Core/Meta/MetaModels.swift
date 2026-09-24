import Foundation

// MARK: - 服务器信息

/// 一次查询取全的服务器信息（`docs/tech-designs/05-session-management.md` §4）。
///
/// 工具栏连接切换器的悬停详情用它显示版本与字符集（`specs/02-workspace.md` §2）。
public struct ServerInfo: Sendable, Equatable, Codable {
    /// `VERSION()` 原文。
    public var version: String
    /// `@@character_set_server`。
    public var charset: String
    /// `@@collation_server`。
    public var collation: String
    /// `@@sql_mode`。
    public var sqlMode: String
    /// `@@character_set_client`；连接实际使用的字符集。
    public var connectionCharset: String
    /// `@@collation_connection`。
    public var connectionCollation: String

    public init(
        version: String = "",
        charset: String = "",
        collation: String = "",
        sqlMode: String = "",
        connectionCharset: String = "",
        connectionCollation: String = ""
    ) {
        self.version = version
        self.charset = charset
        self.collation = collation
        self.sqlMode = sqlMode
        self.connectionCharset = connectionCharset
        self.connectionCollation = connectionCollation
    }

    /// `NO_BACKSLASH_ESCAPES` 是否开启（`09-filtering.md` §1.4、S28）。
    public var hasNoBackslashEscapes: Bool {
        sqlMode
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .contains("NO_BACKSLASH_ESCAPES")
    }
}

// MARK: - 库 / 对象引用

/// `库.表` 引用。纯值类型，便于集合运算与单测。
public struct TableRef: Sendable, Equatable, Hashable, Codable {
    public var database: String
    public var table: String

    public init(database: String, table: String) {
        self.database = database
        self.table = table
    }

    /// 比较用的规范键（库名大小写在 Linux 版 MySQL 下敏感，不做小写折叠）。
    public var identity: String { "\(database).\(table)" }
}

// MARK: - DDL 失效信息

/// 执行一条 SQL 后的元数据失效范围（`11-schema-and-import-export.md` §1.2）。
public struct DDLInvalidation: Sendable, Equatable {
    /// SQL 里是否出现 DDL 关键字。
    public var containsDDL: Bool
    /// 能解析出的 `库.表`。
    public var tables: Set<TableRef>
    /// 只解析出表名、没解析出库名的表；调用方补上当前库。
    public var unqualifiedTables: Set<String>
    /// 解析出的库名（`DROP DATABASE` 等）。
    public var databases: Set<String>
    /// 命中了 DDL 但解析不出对象，保守地失效整个当前库。
    public var unresolved: Bool

    public init(
        containsDDL: Bool = false,
        tables: Set<TableRef> = [],
        unqualifiedTables: Set<String> = [],
        databases: Set<String> = [],
        unresolved: Bool = false
    ) {
        self.containsDDL = containsDDL
        self.tables = tables
        self.unqualifiedTables = unqualifiedTables
        self.databases = databases
        self.unresolved = unresolved
    }

    /// 保守判定：是否应当失效整个库的对象缓存。
    public var invalidatesWholeDatabase: Bool {
        containsDDL && (unresolved || !databases.isEmpty)
    }

    /// 展开出完整表引用（补上当前库）。
    public func resolvedTables(currentDatabase: String?) -> Set<TableRef> {
        var result = tables
        if let currentDatabase {
            for name in unqualifiedTables {
                result.insert(TableRef(database: currentDatabase, table: name))
            }
        }
        return result
    }
}

// MARK: - 查询日志记录

/// 一条下发到服务器的语句的记录（Console Log 用）。
///
/// `MetaRepository` 与 `ConnectionSession` 都产生它，由上层的写入钩子统一落到
/// `ConsoleLogStore`；各 Feature 不再各自记录。见 `06-ui-layer.md` §2。
public struct QueryLogRecord: Sendable, Equatable {
    public var tag: ConsoleLogTag
    public var database: String?
    public var sql: String
    public var durationMilliseconds: Int?
    public var returnedRowCount: Int?
    public var affectedRows: Int64?
    public var errorCode: UInt32?
    public var errorMessage: String?
    public var isCancelled: Bool

    public init(
        tag: ConsoleLogTag,
        database: String? = nil,
        sql: String,
        durationMilliseconds: Int? = nil,
        returnedRowCount: Int? = nil,
        affectedRows: Int64? = nil,
        errorCode: UInt32? = nil,
        errorMessage: String? = nil,
        isCancelled: Bool = false
    ) {
        self.tag = tag
        self.database = database
        self.sql = sql
        self.durationMilliseconds = durationMilliseconds
        self.returnedRowCount = returnedRowCount
        self.affectedRows = affectedRows
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.isCancelled = isCancelled
    }
}

// MARK: - 元数据错误

/// `MetaRepository` 的错误。
public enum MetaRepositoryError: Error, LocalizedError, Equatable {
    case missingResult(String)

    public var errorDescription: String? {
        switch self {
        case .missingResult(let sql): return "元数据查询没有返回结果：\(sql)"
        }
    }
}

// MARK: - information_schema 行

/// `information_schema` 查询结果里的一行：列名 → 值（**原始文本**，`NULL` 为 nil）。
///
/// 纯值类型，让「行 → 模型」的映射成为可单测的纯函数；不直接依赖 `MySQLRow`。
/// 由 `init(_:)` 从 `MySQLBufferedResultSet` 构造时按 UTF-8 解释字节串。
public struct MetaRow: Sendable, Equatable {
    /// 与 `values` 一一对应的列名（小写，便于大小写不敏感查找）。
    public let columnNames: [String]
    public let values: [String?]
    /// 列名（小写）→ 下标。
    private let indexByName: [String: Int]

    public init(columnNames: [String], values: [String?]) {
        self.columnNames = columnNames
        self.values = values
        var index: [String: Int] = [:]
        for (offset, name) in columnNames.enumerated() {
            index[name.lowercased()] = offset
        }
        self.indexByName = index
    }

    /// 由名为 `values` 的字典构造；缺失列视为 `NULL`。测试里手写行时更省事。
    public init(_ values: [String: String?]) {
        let names = values.keys.sorted()
        self.init(columnNames: names, values: names.map { values[$0] ?? nil })
    }

    /// 取原始文本；`NULL` 或列不存在返回 nil。
    public func text(_ name: String) -> String? {
        guard let offset = indexByName[name.lowercased()], offset < values.count else { return nil }
        return values[offset]
    }

    /// 取整数；空串 / `NULL` / 非数字返回 nil。
    public func int(_ name: String) -> Int? {
        guard let text = text(name), !text.isEmpty else { return nil }
        return Int(text)
    }

    /// 取 64 位整数。
    public func int64(_ name: String) -> Int64? {
        guard let text = text(name), !text.isEmpty else { return nil }
        return Int64(text)
    }

    /// 取布尔：MySQL 的 `YES` / `NO` / `1` / `0`。
    public func bool(_ name: String) -> Bool? {
        guard let text = text(name)?.trimmingCharacters(in: .whitespaces).uppercased() else { return nil }
        switch text {
        case "YES", "1", "TRUE": return true
        case "NO", "0", "FALSE": return false
        default: return nil
        }
    }
}

extension MetaRow {
    /// 把一个结果集转成行数组。
    public static func rows(of resultSet: MySQLBufferedResultSet) -> [MetaRow] {
        let names = resultSet.header.columns.map(\.name)
        return resultSet.rows.map { row in
            let values: [String?] = row.cells.map { cell in
                switch cell {
                case .null: return nil
                case .bytes(let data): return String(decoding: data, as: UTF8.self)
                }
            }
            return MetaRow(columnNames: names, values: values)
        }
    }
}
