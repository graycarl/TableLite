import Foundation

/// 一个可以直接转成 MySQL 字面量的值。
///
/// - 从服务器读回的原始字节：文本走 `.text`，二进制（`ColumnInfo.isBinary`）走 `.binary`；
/// - 编辑器产生的值：日期选择器给 `.text`（原样墙钟时间）、布尔给 `.bool`、数字给 `.decimal` / `.integer`。
///
/// 生成规则见 `docs/tech-designs/03-mysql-layer.md` §4.2。
public enum SQLValue: Sendable, Equatable, Hashable {
    case null
    /// 文本 / 日期时间 / JSON 的原始文本。是否加引号由目标列类型与严格数字正则决定。
    case text(String)
    /// 整数。
    case integer(Int64)
    /// 十进制原始文本；通过严格正则时去引号，否则走字符串字面量。
    case decimal(String)
    case bool(Bool)
    /// 二进制，生成 `0x…` 十六进制字面量。
    case binary(Data)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 用于行定位身份字符串 / Diffable 的稳定文本表示。
    public var identityText: String {
        switch self {
        case .null: return "\u{0}null"
        case .text(let value): return "t:\(value)"
        case .integer(let value): return "i:\(value)"
        case .decimal(let value): return "d:\(value)"
        case .bool(let value): return "b:\(value ? 1 : 0)"
        case .binary(let data): return "x:\(data.hexString)"
        }
    }
}

extension SQLValue: Codable {
    private enum CodingKeys: String, CodingKey { case kind, text, integer, bool, data }
    private enum Kind: String, Codable { case null, text, integer, decimal, bool, binary }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .null: self = .null
        case .text: self = .text(try container.decode(String.self, forKey: .text))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .integer))
        case .decimal: self = .decimal(try container.decode(String.self, forKey: .text))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .binary: self = .binary(try container.decode(Data.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .text)
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .integer)
        case .decimal(let value):
            try container.encode(Kind.decimal, forKey: .kind)
            try container.encode(value, forKey: .text)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .bool)
        case .binary(let data):
            try container.encode(Kind.binary, forKey: .kind)
            try container.encode(data, forKey: .data)
        }
    }
}

extension Data {
    /// 大写十六进制字符串，用于二进制显示与 `0x…` 字面量。
    public var hexString: String {
        var result = ""
        result.reserveCapacity(count * 2)
        for byte in self {
            result += String(byte >> 4, radix: 16, uppercase: true)
            result += String(byte & 0x0F, radix: 16, uppercase: true)
        }
        return result
    }
}
