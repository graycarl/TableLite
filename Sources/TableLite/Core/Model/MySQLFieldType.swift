import Foundation

// MARK: - MySQL 字段类型

/// MySQL 字段类型，对应 libmysqlclient 的 `enum_field_types` 数值。
///
/// 用 enum 表达已知类型，`unknown` 兜住未来 / 内部类型，避免解码失败。
/// 类型映射见 `docs/tech-designs/03-mysql-layer.md` §4.1。
public enum MySQLFieldType: Sendable, Hashable {
    case decimal
    case tiny
    case short
    case long
    case float
    case double
    case null
    case timestamp
    case longlong
    case int24
    case date
    case time
    case datetime
    case year
    case newdate
    case varchar
    case bit
    case json
    case newdecimal
    case enumeration
    case set
    case tinyBlob
    case mediumBlob
    case longBlob
    case blob
    case varString
    case string
    case geometry
    case unknown(UInt32)

    public init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .decimal
        case 1: self = .tiny
        case 2: self = .short
        case 3: self = .long
        case 4: self = .float
        case 5: self = .double
        case 6: self = .null
        case 7: self = .timestamp
        case 8: self = .longlong
        case 9: self = .int24
        case 10: self = .date
        case 11: self = .time
        case 12: self = .datetime
        case 13: self = .year
        case 14: self = .newdate
        case 15: self = .varchar
        case 16: self = .bit
        case 245: self = .json
        case 246: self = .newdecimal
        case 247: self = .enumeration
        case 248: self = .set
        case 249: self = .tinyBlob
        case 250: self = .mediumBlob
        case 251: self = .longBlob
        case 252: self = .blob
        case 253: self = .varString
        case 254: self = .string
        case 255: self = .geometry
        default: self = .unknown(rawValue)
        }
    }

    /// `enum_field_types` 数值。
    public var rawValue: UInt32 {
        switch self {
        case .decimal: return 0
        case .tiny: return 1
        case .short: return 2
        case .long: return 3
        case .float: return 4
        case .double: return 5
        case .null: return 6
        case .timestamp: return 7
        case .longlong: return 8
        case .int24: return 9
        case .date: return 10
        case .time: return 11
        case .datetime: return 12
        case .year: return 13
        case .newdate: return 14
        case .varchar: return 15
        case .bit: return 16
        case .json: return 245
        case .newdecimal: return 246
        case .enumeration: return 247
        case .set: return 248
        case .tinyBlob: return 249
        case .mediumBlob: return 250
        case .longBlob: return 251
        case .blob: return 252
        case .varString: return 253
        case .string: return 254
        case .geometry: return 255
        case .unknown(let raw): return raw
        }
    }

    /// 整数 / 小数 / 浮点等需要按数字字面量处理的类型。
    public var isNumeric: Bool {
        switch self {
        case .decimal, .tiny, .short, .long, .float, .double, .longlong, .int24, .newdecimal, .year, .bit:
            return true
        default:
            return false
        }
    }

    /// 日期时间类型。客户端对它们做零处理：原样读、原样写。
    public var isTemporal: Bool {
        switch self {
        case .timestamp, .date, .time, .datetime, .year, .newdate:
            return true
        default:
            return false
        }
    }

    /// BLOB 系列（协议层 TEXT 也会以 BLOB 类型返回，需结合 `ColumnInfo.dataType` 判断）。
    public var isBlobType: Bool {
        switch self {
        case .tinyBlob, .mediumBlob, .longBlob, .blob:
            return true
        default:
            return false
        }
    }

    /// 协议层可判定为大字段的类型（TEXT 需靠 `dataType` 文本判断）。
    public var isLargeObjectType: Bool {
        switch self {
        case .tinyBlob, .mediumBlob, .longBlob, .blob, .json, .geometry:
            return true
        default:
            return false
        }
    }

    /// 字符串 / 文本类型。
    public var isStringType: Bool {
        switch self {
        case .varchar, .varString, .string, .tinyBlob, .mediumBlob, .longBlob, .blob:
            return true
        default:
            return false
        }
    }
}

extension MySQLFieldType: Codable {
    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt32.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 列标志位

/// libmysqlclient 列标志位常量，取自 `mysql_com.h`。
public enum ColumnFlag {
    public static let notNull: UInt32 = 1
    public static let primaryKey: UInt32 = 2
    public static let uniqueKey: UInt32 = 4
    public static let multipleKey: UInt32 = 8
    public static let blob: UInt32 = 16
    public static let unsigned: UInt32 = 32
    public static let zerofill: UInt32 = 64
    public static let binary: UInt32 = 128
    public static let enumFlag: UInt32 = 256
    public static let autoIncrement: UInt32 = 512
    public static let timestamp: UInt32 = 1024
    public static let set: UInt32 = 2048
    public static let noDefaultValue: UInt32 = 4096
    public static let onUpdateNow: UInt32 = 8192
    public static let partKey: UInt32 = 16384
    public static let num: UInt32 = 32768
}
