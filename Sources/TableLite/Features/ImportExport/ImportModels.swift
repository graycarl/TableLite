import Foundation

// MARK: - 目标

/// 导入目标。
public enum ImportTarget: Sendable, Equatable {
    case existingTable(database: String, table: String)
    case newTable(database: String, tableName: String)

    public var database: String {
        switch self {
        case .existingTable(let database, _), .newTable(let database, _): return database
        }
    }

    public var tableName: String {
        switch self {
        case .existingTable(_, let table): return table
        case .newTable(_, let tableName): return tableName
        }
    }

    public var isNewTable: Bool {
        if case .newTable = self { return true }
        return false
    }
}

// MARK: - 列映射

/// 一条 CSV 列 → 目标列的映射。`targetColumn == nil` 表示跳过。
public struct ImportColumnMapping: Sendable, Equatable, Identifiable {
    /// CSV 里的列下标（0-based）。
    public let csvIndex: Int
    /// CSV 里的列名。
    public let csvName: String
    /// 目标列名；nil 表示跳过。
    public var targetColumn: String?
    /// 新表模式下推断 / 手改的类型。
    public var deducedType: CSVColumnType
    /// 说明列（主键 / 非空 / 未匹配到 …）。
    public var note: String

    public var id: Int { csvIndex }
    public var isSkipped: Bool { targetColumn == nil }

    public init(
        csvIndex: Int,
        csvName: String,
        targetColumn: String?,
        deducedType: CSVColumnType,
        note: String
    ) {
        self.csvIndex = csvIndex
        self.csvName = csvName
        self.targetColumn = targetColumn
        self.deducedType = deducedType
        self.note = note
    }
}

/// CSV 列与目标列的自动匹配。纯函数。
public enum ImportColumnMapper {

    /// 按列名自动匹配（大小写不敏感）；匹配不上或目标列已被占用时跳过。
    public static func autoMap(csvColumns: [String], targetColumns: [ColumnInfo]) -> [ImportColumnMapping] {
        var used: Set<String> = []
        return csvColumns.enumerated().map { index, csvName in
            let matched = targetColumns.first { column in
                !used.contains(column.name)
                    && column.name.compare(csvName, options: .caseInsensitive) == .orderedSame
            }
            if let matched {
                used.insert(matched.name)
                return ImportColumnMapping(
                    csvIndex: index,
                    csvName: csvName,
                    targetColumn: matched.name,
                    deducedType: .varchar,
                    note: note(for: matched)
                )
            }
            // 先看名字是否存在但已被前面的 CSV 列占用。
            let exists = targetColumns.contains { $0.name.compare(csvName, options: .caseInsensitive) == .orderedSame }
            return ImportColumnMapping(
                csvIndex: index,
                csvName: csvName,
                targetColumn: nil,
                deducedType: .varchar,
                note: exists ? "目标列已被占用" : "未匹配到"
            )
        }
    }

    /// 说明列文案。
    public static func note(for column: ColumnInfo) -> String {
        var parts: [String] = []
        if column.isPrimaryKey { parts.append("主键") }
        if column.isAutoIncrement { parts.append("自增") }
        if column.isNotNull && !column.isPrimaryKey { parts.append("非空") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// 已映射的目标列（按 CSV 顺序）。
    public static func mappedColumns(
        mappings: [ImportColumnMapping],
        targetColumns: [ColumnInfo]
    ) -> [ColumnInfo] {
        mappings.compactMap { mapping in
            guard let name = mapping.targetColumn else { return nil }
            return targetColumns.first { $0.name == name }
        }
    }

    /// 不可空、无默认值、又是必填却没被映射的目标列；导入前给出警告。
    public static func unmappedRequiredColumns(
        mappings: [ImportColumnMapping],
        targetColumns: [ColumnInfo]
    ) -> [ColumnInfo] {
        let mapped = Set(mappings.compactMap(\.targetColumn))
        return targetColumns.filter { column in
            guard column.isNotNull, !column.isAutoIncrement else { return false }
            if column.hasDefaultValue == true { return false }
            return !mapped.contains(column.name)
        }
    }
}

// MARK: - 行 / 批次 / 失败

/// 一行待插入的数据；`fields` 与「已映射的目标列」一一对应。
public struct ImportRow: Sendable, Equatable {
    public var fields: [String]
    /// 源 CSV 里的行号（1-based）。
    public var lineNumber: Int

    public init(fields: [String], lineNumber: Int) {
        self.fields = fields
        self.lineNumber = lineNumber
    }
}

/// 一批 `INSERT … VALUES (…), (…)`。
public struct ImportInsertBatch: Sendable, Equatable {
    public var sql: String
    public var rows: [ImportRow]

    public init(sql: String, rows: [ImportRow]) {
        self.sql = sql
        self.rows = rows
    }

    public var firstLineNumber: Int { rows.first?.lineNumber ?? 0 }
}

/// 一条失败行。
public struct ImportFailure: Sendable, Equatable {
    public var lineNumber: Int
    public var fields: [String]
    public var message: String

    public init(lineNumber: Int, fields: [String], message: String) {
        self.lineNumber = lineNumber
        self.fields = fields
        self.message = message
    }
}

// MARK: - 选项 / 结果

/// 导入选项。默认值与 `specs/08-import-export.md` §2 第二步一致。
public struct ImportOptions: Sendable, Equatable {
    /// 遇到错误时继续导入其余行。
    public var continueOnError: Bool = false
    /// 导入前先清空目标表（TRUNCATE）。
    public var truncateFirst: Bool = false
    /// 在事务中导入；勾选时要么全部成功要么全部回滚。
    public var useTransaction: Bool = true
    /// 每批行数（`11-schema-and-import-export.md` §4 默认 500）。
    public var batchSize: Int = 500
    /// 空字段是否按 NULL 处理（默认是：导出默认用空串表示 NULL，便于往返）。
    public var emptyFieldIsNull: Bool = true
    public var escaping: SQLStringEscaping = .mysqlDefault
    public var introducer: String? = nil

    public init() {}

    public static let `default` = ImportOptions()
}

/// 导入最终结果。
public struct ImportSummary: Sendable, Equatable {
    public var successCount: Int
    public var failureCount: Int
    public var wasCancelled: Bool
    /// 新建表模式下实际执行的 `CREATE TABLE`。
    public var createdTableSQL: String?
    public var message: String

    public init(
        successCount: Int,
        failureCount: Int,
        wasCancelled: Bool,
        createdTableSQL: String? = nil,
        message: String
    ) {
        self.successCount = successCount
        self.failureCount = failureCount
        self.wasCancelled = wasCancelled
        self.createdTableSQL = createdTableSQL
        self.message = message
    }
}

/// 导入阶段。
public enum ImportPhase: Sendable, Equatable {
    case idle
    case running
    case done(ImportSummary)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - 字段 → SQLValue

/// CSV 字段文本 → `SQLValue`。与手工编辑共用字面量路径。
public enum ImportValueConversion {

    public static func value(from field: String, column: ColumnInfo, emptyIsNull: Bool) -> SQLValue {
        if field.isEmpty {
            return emptyIsNull ? .null : .text("")
        }
        if column.isBinary || column.fieldType.isBlobType, let data = hexData(field) {
            return .binary(data)
        }
        return .text(field)
    }

    /// 解析导出时生成的 `0x…` / `X'…'` 十六进制文本；不是则该格式返回 nil。
    public static func hexData(_ text: String) -> Data? {
        var digits: Substring?
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            digits = text.dropFirst(2)
        } else if text.count >= 3, text.hasPrefix("X'") || text.hasPrefix("x'"), text.hasSuffix("'") {
            digits = text.dropFirst(2).dropLast()
        }
        guard let hex = digits else { return nil }
        return data(fromHex: hex)
    }

    static func data(fromHex hex: Substring) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var high: UInt8?
        for character in hex {
            guard let value = character.hexDigitValue else { return nil }
            if let pending = high {
                bytes.append(pending << 4 | UInt8(value))
                high = nil
            } else {
                high = UInt8(value)
            }
        }
        if let pending = high {
            bytes.append(pending)
        }
        return Data(bytes)
    }
}
