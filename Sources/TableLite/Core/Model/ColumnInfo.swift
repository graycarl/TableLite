import Foundation

/// 列元数据。
///
/// 两种来源共用一个类型：
/// - 结果集列：由 C shim 的 `MTLColumn` 映射（`name` / `originalName` / `flags` / `charsetNumber` …）；
/// - 表结构列：由 `information_schema.COLUMNS` 填充（`dataType` / `columnTypeText` / `isNullable` …），
///   flags 也同步补上主键、自增、非空等位，保证派生属性统一。
///
/// 映射规则见 `docs/tech-designs/03-mysql-layer.md` §4.1 与 `07-data-grid.md` §2 / §3.2。
public struct ColumnInfo: Sendable, Codable, Equatable, Hashable, Identifiable {
    // MARK: 结果集（MTLColumn）

    /// 结果集列名，可能是别名。
    public var name: String
    /// 原始列名（`org_name`）。
    public var originalName: String?
    /// 结果集中的表名，可能是别名。
    public var tableName: String?
    /// 原始表名（`org_table`）。
    public var originalTable: String?
    /// 所属库（`db`）。
    public var database: String?
    public var fieldType: MySQLFieldType
    /// 原始 flags 位。
    public var flags: UInt32
    /// 字符集编号；63 表示 binary。
    public var charsetNumber: UInt32
    /// 显示宽度。`tinyint(1)` 靠它区分。
    public var length: Int
    /// 小数位数。
    public var decimals: Int

    // MARK: information_schema 补充（可空）

    /// `DATA_TYPE`，例如 `text`、`varchar`、`blob`。
    public var dataType: String?
    /// `COLUMN_TYPE` 原文，例如 `tinyint(1)`、`enum('a','b')`、`bigint unsigned`。
    public var columnTypeText: String?
    public var isNullable: Bool?
    public var columnDefault: String?
    /// 是否**定义了**默认值；用它区分「没有默认值」与「默认值为 NULL」。
    public var hasDefaultValue: Bool?
    public var isGenerated: Bool?
    public var generationExpression: String?
    public var comment: String?
    public var characterSet: String?
    public var collation: String?
    public var ordinalPosition: Int?
    public var extra: String?

    public init(
        name: String,
        originalName: String? = nil,
        tableName: String? = nil,
        originalTable: String? = nil,
        database: String? = nil,
        fieldType: MySQLFieldType,
        flags: UInt32 = 0,
        charsetNumber: UInt32 = 0,
        length: Int = 0,
        decimals: Int = 0,
        dataType: String? = nil,
        columnTypeText: String? = nil,
        isNullable: Bool? = nil,
        columnDefault: String? = nil,
        hasDefaultValue: Bool? = nil,
        isGenerated: Bool? = nil,
        generationExpression: String? = nil,
        comment: String? = nil,
        characterSet: String? = nil,
        collation: String? = nil,
        ordinalPosition: Int? = nil,
        extra: String? = nil
    ) {
        self.name = name
        self.originalName = originalName
        self.tableName = tableName
        self.originalTable = originalTable
        self.database = database
        self.fieldType = fieldType
        self.flags = flags
        self.charsetNumber = charsetNumber
        self.length = length
        self.decimals = decimals
        self.dataType = dataType
        self.columnTypeText = columnTypeText
        self.isNullable = isNullable
        self.columnDefault = columnDefault
        self.hasDefaultValue = hasDefaultValue
        self.isGenerated = isGenerated
        self.generationExpression = generationExpression
        self.comment = comment
        self.characterSet = characterSet
        self.collation = collation
        self.ordinalPosition = ordinalPosition
        self.extra = extra
    }

    public var id: String {
        "\(database ?? "").\(originalTable ?? tableName ?? "").\(originalName ?? name)"
    }

    // MARK: flags 派生属性

    public var isNotNull: Bool { flags & ColumnFlag.notNull != 0 }
    public var isPrimaryKey: Bool { flags & ColumnFlag.primaryKey != 0 }
    public var isUniqueKey: Bool { flags & ColumnFlag.uniqueKey != 0 }
    public var isUnsigned: Bool { flags & ColumnFlag.unsigned != 0 }
    public var isAutoIncrement: Bool { flags & ColumnFlag.autoIncrement != 0 }
    public var isZerofill: Bool { flags & ColumnFlag.zerofill != 0 }
    public var isEnumFlag: Bool { flags & ColumnFlag.enumFlag != 0 }
    public var isSetFlag: Bool { flags & ColumnFlag.set != 0 }

    /// 是否按二进制处理：字符集为 binary（63）或带 `BINARY_FLAG`。
    public var isBinary: Bool { charsetNumber == 63 || flags & ColumnFlag.binary != 0 }

    /// 协议层 BLOB 标志。
    public var isBlobFlag: Bool { flags & ColumnFlag.blob != 0 }

    /// `TINYINT(1)`：是否可当作布尔显示由偏好决定，默认关闭。
    public var isBooleanTinyInt: Bool { fieldType == .tiny && length == 1 }

    /// 数字类型（含 unsigned 变体）。
    public var isNumeric: Bool { fieldType.isNumeric }

    public var isTemporal: Bool { fieldType.isTemporal }

    /// 大字段：TEXT / BLOB / JSON / GEOMETRY 系列。用于两阶段加载。
    public var isLargeObject: Bool {
        if let dataType = dataType?.lowercased(), Self.largeObjectDataTypes.contains(dataType) {
            return true
        }
        return fieldType.isLargeObjectType
    }

    /// `information_schema.DATA_TYPE` 里属于大字段的取值。
    public static let largeObjectDataTypes: Set<String> = [
        "tinytext", "text", "mediumtext", "longtext",
        "tinyblob", "blob", "mediumblob", "longblob",
        "json", "geometry", "point", "linestring", "polygon",
        "multipoint", "multilinestring", "multipolygon", "geometrycollection", "geomcollection",
    ]

    /// 从 `COLUMN_TYPE` 文本里解析 `ENUM` / `SET` 的值域。
    ///
    /// 例：`enum('a','b','c')` → `["a", "b", "c"]`。
    public var enumValues: [String]? {
        guard fieldType == .enumeration || fieldType == .set || isEnumFlag || isSetFlag else {
            return nil
        }
        guard let text = columnTypeText else { return nil }
        return Self.parseEnumValues(from: text)
    }

    /// 解析 `enum(...)` / `set(...)` 里的值。纯函数，供字段栏下拉与过滤条件值下拉使用。
    public static func parseEnumValues(from columnType: String) -> [String]? {
        guard let open = columnType.firstIndex(of: "("),
              let close = columnType.lastIndex(of: ")"),
              open < close else {
            return nil
        }
        let body = columnType[columnType.index(after: open)..<close]
        var values: [String] = []
        var current = ""
        var inQuote = false
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if inQuote {
                if character == "\\", body.index(after: index) < body.endIndex {
                    let next = body[body.index(after: index)]
                    current.append(next)
                    index = body.index(index, offsetBy: 2)
                    continue
                }
                if character == "'" {
                    // 两个连续单引号表示一个单引号。
                    let next = body.index(after: index)
                    if next < body.endIndex, body[next] == "'" {
                        current.append("'")
                        index = body.index(index, offsetBy: 2)
                        continue
                    }
                    inQuote = false
                    values.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            } else if character == "'" {
                inQuote = true
                current = ""
            }
            index = body.index(after: index)
        }
        return values.isEmpty ? nil : values
    }
}
