import Foundation

// MARK: - 单元格原始值
//
// MySQL 文本协议把每个值都作为「原始字节」返回。Swift 侧不在这里做类型转换，
// 只保留字节；由列类型（ColumnKind / TableColumn.kind）决定怎么显示与编辑。
// 见 docs/tech-designs/03-mysql-layer.md §4.1。

enum CellValue: Hashable, Sendable {
    case null
    case bytes([UInt8])

    static func text(_ string: String) -> CellValue {
        .bytes(Array(string.utf8))
    }

    static func data(_ data: Data) -> CellValue {
        .bytes(Array(data))
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var byteCount: Int {
        if case .bytes(let bytes) = self { return bytes.count }
        return 0
    }

    var bytes: [UInt8]? {
        if case .bytes(let bytes) = self { return bytes }
        return nil
    }

    var data: Data? {
        if case .bytes(let bytes) = self { return Data(bytes) }
        return nil
    }

    /// 宽松解码（非法 UTF-8 序列替换为 U+FFFD），只用于显示。
    var displayText: String {
        switch self {
        case .null: return ""
        case .bytes(let bytes): return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// 严格 UTF-8 解码；失败返回 nil（说明是二进制内容）。
    var strictText: String? {
        guard case .bytes(let bytes) = self else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}

// MARK: - 列类型

/// 列在界面上表现出的「类型家族」。用于选编辑器、校验、对齐、截断策略。
enum ColumnKind: Hashable, Sendable {
    case integer(isUnsigned: Bool)
    case decimal
    case floating
    case text
    case blob
    case json
    case date
    case time
    case dateTime
    case timestamp
    case year
    case enumType
    case setType
    case bit
    case geometry
    case boolean
    case unknown(String)

    var isNumeric: Bool {
        switch self {
        case .integer, .decimal, .floating: return true
        default: return false
        }
    }

    var isDateTime: Bool {
        switch self {
        case .date, .time, .dateTime, .timestamp, .year: return true
        default: return false
        }
    }

    /// 二进制家族：文本编辑器不可用，只能查看 / 从文件导入 / 设为 NULL。
    var isBinaryLike: Bool {
        switch self {
        case .blob, .bit, .geometry: return true
        default: return false
        }
    }

    var isTextLike: Bool {
        switch self {
        case .text, .json, .enumType, .setType: return true
        default: return false
        }
    }

    /// 大字段（两阶段加载的判定对象）。见 docs/tech-designs/07-data-grid.md §3.1。
    var isLargeObjectFamily: Bool {
        switch self {
        case .text, .blob, .json, .geometry: return true
        default: return false
        }
    }
}

/// `information_schema.COLUMNS` / 连接配置给出的类型信息 → `ColumnKind`。
/// 纯函数，单元测试覆盖 `tinyint(1)`、`bigint unsigned`、`enum(...)`、`decimal(10,2)`。
enum ColumnKindClassifier {

    static func kind(dataType: String, rawTypeText: String) -> ColumnKind {
        let data = dataType.lowercased()
        let raw = rawTypeText.lowercased()
        let unsigned = raw.contains("unsigned")
        switch data {
        case "tinyint":
            // tinyint(1) 默认按整数显示；是否当布尔由偏好决定，见 `TableColumn.isTinyInt1`。
            if raw.hasPrefix("tinyint(1)") { return .boolean }
            return .integer(isUnsigned: unsigned)
        case "smallint", "mediumint", "int", "integer", "bigint":
            return .integer(isUnsigned: unsigned)
        case "decimal", "numeric":
            return .decimal
        case "float", "double", "real":
            return .floating
        case "char", "varchar", "tinytext", "text", "mediumtext", "longtext":
            return .text
        case "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob":
            return .blob
        case "json":
            return .json
        case "date":
            return .date
        case "time":
            return .time
        case "datetime":
            return .dateTime
        case "timestamp":
            return .timestamp
        case "year":
            return .year
        case "enum":
            return .enumType
        case "set":
            return .setType
        case "bit":
            return .bit
        case "geometry", "point", "linestring", "polygon", "multipoint",
             "multilinestring", "multipolygon", "geometrycollection":
            return .geometry
        default:
            return .unknown(data)
        }
    }

    /// `enum('a','b')` / `set('x','y')` 的取值列表。解析失败返回 nil。
    static func enumValues(rawTypeText: String) -> [String]? {
        guard let open = rawTypeText.firstIndex(of: "("),
              let close = rawTypeText.lastIndex(of: ")"),
              open < close else { return nil }
        let body = rawTypeText[rawTypeText.index(after: open)..<close]
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var values: [String] = []
        var current = ""
        var inQuote = false
        var index = body.startIndex
        while index < body.endIndex {
            let ch = body[index]
            if inQuote {
                if ch == "'" {
                    let next = body.index(after: index)
                    if next < body.endIndex && body[next] == "'" {
                        current.append("'")
                        index = body.index(after: next)
                        continue
                    }
                    inQuote = false
                } else if ch == "\\" {
                    let next = body.index(after: index)
                    if next < body.endIndex {
                        current.append(body[next])
                        index = body.index(after: next)
                        continue
                    }
                    current.append(ch)
                } else {
                    current.append(ch)
                }
            } else if ch == "'" {
                inQuote = true
            } else if ch == "," {
                values.append(current)
                current = ""
            } else if !ch.isWhitespace {
                current.append(ch)
            }
            index = body.index(after: index)
        }
        values.append(current)
        return values
    }
}

// MARK: - 结果集列（来自 libmysqlclient）

/// `enum_field_types` 的原始数值。见 mysql_com.h。
enum MySQLFieldType {
    static let decimal: UInt32 = 0
    static let tiny: UInt32 = 1
    static let short: UInt32 = 2
    static let long: UInt32 = 3
    static let float: UInt32 = 4
    static let double: UInt32 = 5
    static let null: UInt32 = 6
    static let timestamp: UInt32 = 7
    static let longlong: UInt32 = 8
    static let int24: UInt32 = 9
    static let date: UInt32 = 10
    static let time: UInt32 = 11
    static let datetime: UInt32 = 12
    static let year: UInt32 = 13
    static let varchar: UInt32 = 15
    static let bit: UInt32 = 16
    static let json: UInt32 = 245
    static let newdecimal: UInt32 = 246
    static let enumType: UInt32 = 247
    static let setType: UInt32 = 248
    static let tinyBlob: UInt32 = 249
    static let mediumBlob: UInt32 = 250
    static let longBlob: UInt32 = 251
    static let blob: UInt32 = 252
    static let varString: UInt32 = 253
    static let string: UInt32 = 254
    static let geometry: UInt32 = 255
    /// 63 = binary charset，用于判断列是不是二进制。
    static let binaryCharsetNumber: UInt32 = 63
}

/// libmysqlclient 的 `MYSQL_FIELD` 映射。字符串生命周期与结果集一致，构造时立刻复制。
struct ResultSetColumn: Hashable, Sendable {
    var name: String
    var originalTable: String?
    var originalColumn: String?
    var database: String?
    var fieldType: UInt32
    var flags: UInt32
    var charsetNumber: UInt32
    var length: UInt32
    var decimals: UInt32
    var kind: ColumnKind
    /// 二进制列（charset 63 或 BINARY_FLAG）
    var isBinary: Bool
    /// NOT_NULL_FLAG
    var isNotNull: Bool
    /// PRI_KEY_FLAG
    var isPrimaryKey: Bool
    /// UNSIGNED_FLAG
    var isUnsigned: Bool
    /// AUTO_INCREMENT_FLAG
    var isAutoIncrement: Bool

    static func classify(fieldType: UInt32, charsetNumber: UInt32) -> ColumnKind {
        let isBinary = charsetNumber == MySQLFieldType.binaryCharsetNumber
        switch fieldType {
        case MySQLFieldType.decimal, MySQLFieldType.newdecimal:
            return .decimal
        case MySQLFieldType.tiny, MySQLFieldType.short, MySQLFieldType.long,
             MySQLFieldType.longlong, MySQLFieldType.int24:
            return .integer(isUnsigned: false)
        case MySQLFieldType.float, MySQLFieldType.double:
            return .floating
        case MySQLFieldType.date:
            return .date
        case MySQLFieldType.time:
            return .time
        case MySQLFieldType.datetime:
            return .dateTime
        case MySQLFieldType.timestamp:
            return .timestamp
        case MySQLFieldType.year:
            return .year
        case MySQLFieldType.json:
            return .json
        case MySQLFieldType.enumType:
            return .enumType
        case MySQLFieldType.setType:
            return .setType
        case MySQLFieldType.bit:
            return .bit
        case MySQLFieldType.geometry:
            return .geometry
        case MySQLFieldType.tinyBlob, MySQLFieldType.mediumBlob,
             MySQLFieldType.longBlob, MySQLFieldType.blob:
            return .blob
        case MySQLFieldType.varchar, MySQLFieldType.varString, MySQLFieldType.string:
            return isBinary ? .blob : .text
        default:
            return isBinary ? .blob : .text
        }
    }
}

// MARK: - 表列（来自 information_schema）

/// 表结构里的一列。数据网格与字段栏都以它为准（见 docs/tech-designs/07-data-grid.md §3.2）。
struct TableColumn: Hashable, Sendable {
    var name: String
    /// 在表中的顺序（1-based，来自 `ORDINAL_POSITION`）
    var position: Int
    /// `DATA_TYPE`，例如 `varchar`
    var dataType: String
    /// `COLUMN_TYPE` 原始文本，例如 `varchar(255)` / `enum('a','b')`
    var rawTypeText: String
    var isNullable: Bool
    var isPrimaryKey: Bool
    var isAutoIncrement: Bool
    var isUnsigned: Bool
    /// 二进制字符集（`binary` / `varbinary` / blob 系列）
    var isBinary: Bool
    var isGenerated: Bool
    /// 不可见列默认不显示
    var isInvisible: Bool
    var charset: String?
    var collation: String?
    /// 没有默认值 → nil；默认值是 SQL NULL → "NULL"
    var defaultValue: String?
    var comment: String?
    var kind: ColumnKind
    /// ENUM / SET 的可选值
    var enumValues: [String]?

    /// `tinyint(1)` —— 是否显示为复选框由偏好控制，默认关闭。
    var isTinyInt1: Bool {
        dataType.lowercased() == "tinyint" && rawTypeText.lowercased().hasPrefix("tinyint(1)")
    }

    /// 大字段（TEXT / BLOB / JSON / GEOMETRY 系列）需要两阶段加载。
    /// `CHAR` / `VARCHAR` 不算：它们长度有上限，不会让一页数据膨胀。
    /// 见 docs/tech-designs/07-data-grid.md §3.1。
    var isLargeObject: Bool {
        switch dataType.lowercased() {
        case "tinytext", "text", "mediumtext", "longtext",
             "tinyblob", "blob", "mediumblob", "longblob",
             "json",
             "geometry", "point", "linestring", "polygon",
             "multipoint", "multilinestring", "multipolygon", "geometrycollection":
            return true
        default:
            return false
        }
    }

    init(
        name: String,
        position: Int = 0,
        dataType: String,
        rawTypeText: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        isAutoIncrement: Bool = false,
        isUnsigned: Bool = false,
        isBinary: Bool = false,
        isGenerated: Bool = false,
        isInvisible: Bool = false,
        charset: String? = nil,
        collation: String? = nil,
        defaultValue: String? = nil,
        comment: String? = nil,
        kind: ColumnKind? = nil,
        enumValues: [String]? = nil
    ) {
        self.name = name
        self.position = position
        self.dataType = dataType
        self.rawTypeText = rawTypeText
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.isAutoIncrement = isAutoIncrement
        self.isUnsigned = isUnsigned
        self.isBinary = isBinary
        self.isGenerated = isGenerated
        self.isInvisible = isInvisible
        self.charset = charset
        self.collation = collation
        self.defaultValue = defaultValue
        self.comment = comment
        self.kind = kind ?? ColumnKindClassifier.kind(dataType: dataType, rawTypeText: rawTypeText)
        self.enumValues = enumValues
            ?? (self.kind == .enumType || self.kind == .setType
                ? ColumnKindClassifier.enumValues(rawTypeText: rawTypeText)
                : nil)
    }
}
