import Foundation

/// 字段栏编辑器的种类（`specs/04-data-editing.md` §3、`docs/tech-designs/14-row-inspector.md` §3）。
///
/// 纯值类型；由列类型与偏好决定，供 `InspectorFieldRow` 选择控件，也便于单测。
public enum FieldEditorKind: Sendable, Equatable {
    /// 普通文本：单行输入框。
    case singleLineText
    /// 数字：单行输入框，右对齐。
    case number
    /// 长文本 / JSON：内联多行 + 展开。
    case multilineText
    /// 日期 / 时间：原样文本框（客户端不做时区处理，`03-mysql-layer.md` §4.3）。
    case temporal
    /// `ENUM`：下拉。
    case enumeration([String])
    /// `SET`：多选。
    case set([String])
    /// `TINYINT(1)`（偏好开启时）：三态复选框。
    case booleanTinyInt
    /// BLOB / 二进制：不允许直接改文本。
    case binary

    public var isTextLike: Bool {
        switch self {
        case .singleLineText, .number, .multilineText, .temporal, .enumeration, .set:
            return true
        case .booleanTinyInt, .binary:
            return false
        }
    }

    public var isMultiline: Bool {
        self == .multilineText
    }
}

/// 由列元数据确定编辑器种类。纯函数。
public enum FieldEditorResolver {

    public static func kind(for column: ColumnInfo, tinyintAsCheckbox: Bool) -> FieldEditorKind {
        if column.fieldType == .enumeration, let values = column.enumValues {
            return .enumeration(values)
        }
        if column.fieldType == .set, let values = column.enumValues {
            return .set(values)
        }
        if tinyintAsCheckbox, column.isBooleanTinyInt {
            return .booleanTinyInt
        }
        // 数字 / 日期时间先于二进制判定：MySQL 把数值列也报成 charset 63（`isBinary == true`）。
        if column.isNumeric {
            return .number
        }
        if column.isTemporal {
            return .temporal
        }
        // 二进制 / BLOB：不可文本编辑。
        if column.isBinary || column.fieldType == .geometry {
            return .binary
        }
        if column.isLargeObject || column.fieldType == .json {
            return .multilineText
        }
        return .singleLineText
    }
}

/// 字段值校验失败的原因。文案对应 `specs/04-data-editing.md` §3「校验」。
public enum FieldEditValidationError: Error, Sendable, Equatable {
    case notANumber
    case invalidDate
    case invalidTime
    case invalidDateTime
    case invalidYear
    case valueNotInEnum
    case valueNotInSet(String)

    public var message: String {
        switch self {
        case .notANumber: return "请输入合法数字（可含负号与小数点）"
        case .invalidDate: return "日期格式应为 YYYY-MM-DD"
        case .invalidTime: return "时间格式应为 HH:MM:SS"
        case .invalidDateTime: return "日期时间格式应为 YYYY-MM-DD HH:MM:SS"
        case .invalidYear: return "年份应为 4 位数字"
        case .valueNotInEnum: return "值不在该列的 ENUM 取值范围内"
        case .valueNotInSet(let value): return "值 \(value) 不在该列的 SET 取值范围内"
        }
    }
}

/// 字段编辑的校验与文本 ↔ 值转换。纯函数，方便单测。
public enum FieldEditValidator {

    /// 校验草稿文本。返回 nil 表示通过。空串永远通过（提交给服务器判断）。
    public static func validate(text: String, column: ColumnInfo, kind: FieldEditorKind) -> FieldEditValidationError? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch kind {
        case .number:
            // 数字列只接受严格数字（含负号与小数点）；`1e5` / `0x1` 不接受。
            return SQLValueLiteral.isStrictNumber(trimmed) ? nil : .notANumber

        case .temporal:
            switch column.fieldType {
            case .date, .newdate:
                return isDate(trimmed) ? nil : .invalidDate
            case .time:
                return isTime(trimmed) ? nil : .invalidTime
            case .year:
                return isYear(trimmed) ? nil : .invalidYear
            default:
                return isDateTime(trimmed) ? nil : .invalidDateTime
            }

        case .enumeration(let values):
            return values.contains(trimmed) ? nil : .valueNotInEnum

        case .set(let values):
            for part in trimmed.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !values.contains(part) {
                return .valueNotInSet(part)
            }
            return nil

        case .singleLineText, .multilineText, .booleanTinyInt, .binary:
            return nil
        }
    }

    /// 文本 → 存储值。数字列保留 `.text`，由 `SQLValueLiteral` 按列类型决定是否去引号。
    public static func value(fromText text: String, column: ColumnInfo, kind: FieldEditorKind) -> SQLValue {
        switch kind {
        case .booleanTinyInt:
            return .bool(text == "1")
        default:
            return .text(text)
        }
    }

    /// 存储值 → 编辑器文本。`NULL` 由调用方单独处理（灰斜体 `NULL`）。
    public static func text(from value: SQLValue) -> String {
        switch value {
        case .null: return ""
        case .text(let text): return text
        case .integer(let number): return String(number)
        case .decimal(let text): return text
        case .bool(let flag): return flag ? "1" : "0"
        case .binary(let data): return data.hexString
        }
    }

    // MARK: 日期时间格式（只做格式校验，不做时区换算）

    public static func isDate(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        guard let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        guard parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        guard (1...12).contains(month), (1...31).contains(day) else { return false }
        return year >= 0
    }

    public static func isTime(_ text: String) -> Bool {
        let timePart = text.split(separator: ".").first.map(String.init) ?? text
        let parts = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        guard parts[0].count == 2, parts[1].count == 2, (0...23).contains(hour), (0...59).contains(minute) else { return false }
        if parts.count == 3 {
            guard let second = Int(parts[2]), parts[2].count == 2, (0...59).contains(second) else { return false }
        }
        return true
    }

    public static func isDateTime(_ text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        let pieces = normalized.split(separator: " ", omittingEmptySubsequences: true)
        guard pieces.count == 2 else { return false }
        return isDate(String(pieces[0])) && isTime(String(pieces[1]))
    }

    public static func isYear(_ text: String) -> Bool {
        text.count == 4 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
