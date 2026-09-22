import Foundation
import Darwin
import CMySQLClient

// MARK: - 单元格

/// 从服务器读回的一个单元格：只保留**原始字节**，类型解释交给上层。
///
/// `NULL` 与空串必须区分，见 `docs/tech-designs/03-mysql-layer.md` §1。
public enum MySQLCell: Sendable, Equatable, Hashable {
    case null
    case bytes(Data)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 按 UTF-8 解释的文本；`NULL` 返回 nil。数字 / 日期时间也用这个取「十进制原样文本」。
    public var text: String? {
        switch self {
        case .null: return nil
        case .bytes(let data): return String(decoding: data, as: UTF8.self)
        }
    }
}

// MARK: - 结果集 / 行

/// 结果集的列元数据与 OK 包信息。
public struct MySQLResultSetHeader: Sendable, Equatable {
    /// 第几个结果集，从 0 开始（与 C 回调的 `result_index` 一致）。
    public let index: Int
    /// 列元数据；为空表示这是一个 OK 包（没有结果集，只有影响行数）。
    public let columns: [ColumnInfo]
    public let affectedRows: Int64
    public let lastInsertID: UInt64

    public init(index: Int, columns: [ColumnInfo], affectedRows: Int64, lastInsertID: UInt64) {
        self.index = index
        self.columns = columns
        self.affectedRows = affectedRows
        self.lastInsertID = lastInsertID
    }

    /// `true` 表示带列的结果集；`false` 表示 OK / 影响行数。
    public var hasColumns: Bool { !columns.isEmpty }
}

/// 一行数据。按结果集分组，`cells` 与列一一对应。
public struct MySQLRow: Sendable, Equatable {
    public let resultIndex: Int
    public let rowIndex: Int64
    public let cells: [MySQLCell]

    public init(resultIndex: Int, rowIndex: Int64, cells: [MySQLCell]) {
        self.resultIndex = resultIndex
        self.rowIndex = rowIndex
        self.cells = cells
    }

    /// `cells[i]` 对应 `columns[i]`。
    public func values(columns: [ColumnInfo]) -> [SQLValue] {
        MySQLValueMapping.values(for: self, columns: columns)
    }
}

/// 执行期间的一条流式事件。上层逐事件消费（`03-mysql-layer.md` §3）。
public enum MySQLQueryEvent: Sendable {
    case resultSet(MySQLResultSetHeader)
    case row(MySQLRow)
    case statementError(MySQLStatementError)
}

/// 单条语句的错误。多语句下发时，出错后仍会继续后续结果集。
public struct MySQLStatementError: Error, Sendable, Equatable {
    public let resultIndex: Int
    public let error: MySQLError

    public init(resultIndex: Int, error: MySQLError) {
        self.resultIndex = resultIndex
        self.error = error
    }
}

// MARK: - 汇总 / 缓冲结果

/// 一次下发的汇总。流式接口返回它。
public struct MySQLQuerySummary: Sendable, Equatable {
    public let resultSetCount: Int
    public let rowCount: Int
    public let affectedRows: Int64
    public let lastInsertID: UInt64
    public let statementErrors: [MySQLStatementError]
    public let wasCancelled: Bool

    public init(
        resultSetCount: Int,
        rowCount: Int,
        affectedRows: Int64,
        lastInsertID: UInt64,
        statementErrors: [MySQLStatementError],
        wasCancelled: Bool
    ) {
        self.resultSetCount = resultSetCount
        self.rowCount = rowCount
        self.affectedRows = affectedRows
        self.lastInsertID = lastInsertID
        self.statementErrors = statementErrors
        self.wasCancelled = wasCancelled
    }

    public var hasErrors: Bool { !statementErrors.isEmpty }
    public var firstError: MySQLError? { statementErrors.first?.error }
}

/// 一个带行的缓冲结果集。
public struct MySQLBufferedResultSet: Sendable, Equatable {
    public let header: MySQLResultSetHeader
    public var rows: [MySQLRow]

    public init(header: MySQLResultSetHeader, rows: [MySQLRow]) {
        self.header = header
        self.rows = rows
    }
}

/// 缓冲模式（`execute`）的完整结果。
public struct MySQLQueryResult: Sendable, Equatable {
    public let resultSets: [MySQLBufferedResultSet]
    public let statementErrors: [MySQLStatementError]
    public let wasCancelled: Bool
    public let rowCount: Int
    public let affectedRows: Int64
    public let lastInsertID: UInt64

    public init(
        resultSets: [MySQLBufferedResultSet],
        statementErrors: [MySQLStatementError],
        wasCancelled: Bool,
        rowCount: Int,
        affectedRows: Int64,
        lastInsertID: UInt64
    ) {
        self.resultSets = resultSets
        self.statementErrors = statementErrors
        self.wasCancelled = wasCancelled
        self.rowCount = rowCount
        self.affectedRows = affectedRows
        self.lastInsertID = lastInsertID
    }

    public var hasErrors: Bool { !statementErrors.isEmpty }
    public var firstError: MySQLError? { statementErrors.first?.error }

    /// 带列的第一个结果集。
    public var firstResultSet: MySQLBufferedResultSet? {
        resultSets.first { $0.header.hasColumns }
    }
}

// MARK: - 类型映射（纯函数）

/// 原始字节 + 列元数据 → `SQLValue`。
///
/// 规则见 `docs/tech-designs/03-mysql-layer.md` §4.1：
/// 二进制列走 `.binary`，其余一律 `.text`（数字保留十进制原样文本，不做浮点转换；
/// 日期时间原样文本，不做时区处理）。
public enum MySQLValueMapping {
    public static func value(for cell: MySQLCell, column: ColumnInfo) -> SQLValue {
        switch cell {
        case .null:
            return .null
        case .bytes(let data):
            return isBinaryColumn(column) ? .binary(data) : .text(String(decoding: data, as: UTF8.self))
        }
    }

    /// 是否是真正的二进制字符串列。
    ///
    /// 协议层把数字 / 日期时间列的 charset 也报成 63（`ColumnInfo.isBinary == true`），
    /// 所以不能只看 `isBinary`：只有字符串 / BLOB / JSON / GEOMETRY / BIT 才按二进制处理，
    /// 否则整数主键会被 hex 化成 `0x31`，导致 `WHERE id = 0x31` 定位不到行。
    static func isBinaryColumn(_ column: ColumnInfo) -> Bool {
        guard column.isBinary else { return false }
        switch column.fieldType {
        case .varchar, .varString, .string, .tinyBlob, .mediumBlob, .longBlob, .blob, .json, .geometry, .bit:
            return true
        default:
            return false
        }
    }

    public static func values(for row: MySQLRow, columns: [ColumnInfo]) -> [SQLValue] {
        row.cells.enumerated().map { index, cell in
            guard index < columns.count else {
                return cell.isNull ? .null : .text(cell.text ?? "")
            }
            return value(for: cell, column: columns[index])
        }
    }
}

// MARK: - C 结构体映射

extension ColumnInfo {
    /// 由 C shim 的 `MTLColumn` 映射。字符串指针只在回调期间有效，这里全部复制。
    init(mtlColumn column: MTLColumn) {
        self.init(
            name: mysqlCString(column.name),
            originalName: column.original_name.map { mysqlCString($0) },
            tableName: column.table.map { mysqlCString($0) },
            originalTable: column.original_table.map { mysqlCString($0) },
            database: column.database.map { mysqlCString($0) },
            fieldType: MySQLFieldType(rawValue: column.type),
            flags: column.flags,
            charsetNumber: column.charset_nr,
            length: Int(column.length),
            decimals: Int(column.decimals)
        )
    }
}

extension MySQLResultSetHeader {
    init(_ raw: MTLResultSet) {
        var columns: [ColumnInfo] = []
        if raw.column_count > 0, let rawColumns = raw.columns {
            columns.reserveCapacity(Int(raw.column_count))
            for index in 0..<Int(raw.column_count) {
                columns.append(ColumnInfo(mtlColumn: rawColumns[index]))
            }
        }
        self.init(
            index: Int(raw.result_index),
            columns: columns,
            affectedRows: raw.affected_rows,
            lastInsertID: raw.last_insert_id
        )
    }
}

extension MySQLRow {
    /// 由 C 回调的 `MTLRow` 映射。
    ///
    /// `mysql_fetch_row` 的缓冲区会被下一次调用复用，所以这里**必须**复制；
    /// 而且 `values[i] == NULL` 表示 SQL NULL，不能用 `strlen`（可能含 `\0`），
    /// 长度一律取 `mysql_fetch_lengths`。见 `docs/tech-designs/03-mysql-layer.md` §1。
    init(_ raw: MTLRow) {
        let columnCount = Int(raw.column_count)
        var cells: [MySQLCell] = []
        cells.reserveCapacity(columnCount)
        if let values = raw.values {
            for index in 0..<columnCount {
                guard let value = values[index] else {
                    cells.append(.null)
                    continue
                }
                let length = raw.lengths.map { Int($0[index]) } ?? 0
                cells.append(.bytes(Data(bytes: value, count: length)))
            }
        } else {
            cells = Array(repeating: .null, count: columnCount)
        }
        self.init(resultIndex: Int(raw.result_index), rowIndex: raw.row_index, cells: cells)
    }
}

// MARK: - 工具

/// 复制 C 字符串；nil 返回空串。
func mysqlCString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)), as: UTF8.self)
}
