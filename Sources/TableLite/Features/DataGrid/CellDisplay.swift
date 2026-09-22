import Foundation

// MARK: - 字节大小

/// 把字节数格式化成界面文案：`25 B` / `12.3 KB` / `1.2 MB`。
///
/// 见 `specs/03-data-browsing.md` §4「数字与单位之间加空格」。
public enum ByteSize {
    public static func format(_ bytes: Int) -> String {
        let value = max(0, bytes)
        if value < 1024 {
            return "\(value) B"
        }
        let kb = Double(value) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.1f GB", mb / 1024)
    }
}

// MARK: - 二进制类型识别

/// 二进制内容的类型识别结果。
public struct BinaryFormatInfo: Sendable, Equatable {
    /// 文件类型简称，例如 `PNG`、`JPEG`、`SQLite`。
    public var displayName: String
    /// 是否是可直接预览的图片。
    public var isImage: Bool
    /// 导出时建议的扩展名（不带点）。
    public var fileExtension: String?

    public init(displayName: String, isImage: Bool = false, fileExtension: String? = nil) {
        self.displayName = displayName
        self.isImage = isImage
        self.fileExtension = fileExtension
    }

    public static let unknown = BinaryFormatInfo(displayName: "二进制")
}

/// 按魔术字节识别二进制类型。纯函数，见 `specs/03-data-browsing.md` §4。
public enum BinaryFormatDetector {

    public static func detect(_ data: Data) -> BinaryFormatInfo {
        let bytes = [UInt8](data.prefix(16))
        guard !bytes.isEmpty else { return BinaryFormatInfo(displayName: "空二进制") }

        func starts(with signature: [UInt8]) -> Bool {
            guard bytes.count >= signature.count else { return false }
            return Array(bytes.prefix(signature.count)) == signature
        }

        if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return BinaryFormatInfo(displayName: "PNG", isImage: true, fileExtension: "png")
        }
        if starts(with: [0xFF, 0xD8, 0xFF]) {
            return BinaryFormatInfo(displayName: "JPEG", isImage: true, fileExtension: "jpg")
        }
        if starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return BinaryFormatInfo(displayName: "GIF", isImage: true, fileExtension: "gif")
        }
        if starts(with: [0x52, 0x49, 0x46, 0x46]), bytes.count >= 12,
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return BinaryFormatInfo(displayName: "WebP", isImage: true, fileExtension: "webp")
        }
        if starts(with: [0x42, 0x4D]) {
            return BinaryFormatInfo(displayName: "BMP", isImage: true, fileExtension: "bmp")
        }
        if starts(with: [0x49, 0x49, 0x2A, 0x00]) || starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return BinaryFormatInfo(displayName: "TIFF", isImage: true, fileExtension: "tiff")
        }
        if starts(with: [0x00, 0x00, 0x01, 0x00]) {
            return BinaryFormatInfo(displayName: "ICO", isImage: true, fileExtension: "ico")
        }
        if starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return BinaryFormatInfo(displayName: "PDF", fileExtension: "pdf")
        }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) || starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return BinaryFormatInfo(displayName: "ZIP", fileExtension: "zip")
        }
        if starts(with: [0x1F, 0x8B]) {
            return BinaryFormatInfo(displayName: "GZIP", fileExtension: "gz")
        }
        if starts(with: [0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00]) {
            return BinaryFormatInfo(displayName: "SQLite", fileExtension: "sqlite")
        }
        return .unknown
    }
}

// MARK: - 单元格显示

public enum CellAlignment: Sendable, Equatable {
    case leading
    case trailing
    case center
}

/// 单元格渲染的输入偏好。
public struct CellDisplayContext: Sendable, Equatable {
    /// `NULL` 的显示文本（偏好 `grid.nullDisplayText`）。
    public var nullText: String
    /// 是否把 `tinyint(1)` 显示为复选框（偏好）。
    public var tinyintAsCheckbox: Bool
    /// 短二进制直接显示 hex 的字节上限。
    public var shortBinaryLimit: Int

    public init(nullText: String = "NULL", tinyintAsCheckbox: Bool = false, shortBinaryLimit: Int = 32) {
        self.nullText = nullText
        self.tinyintAsCheckbox = tinyintAsCheckbox
        self.shortBinaryLimit = shortBinaryLimit
    }

    public static let `default` = CellDisplayContext()
}

/// 三态复选框状态。
public enum CellCheckboxState: Sendable, Equatable {
    case off
    case on
    case mixed
}

/// 一个单元格的展示描述。纯值类型，AppKit / SwiftUI 两侧共用。
public struct CellDisplay: Sendable, Equatable {
    public var text: String
    public var isNull: Bool
    public var isTruncated: Bool
    public var alignment: CellAlignment
    public var tooltip: String?
    /// 非 nil 时以三态复选框渲染（`true` / `false` / `NULL`）。
    public var checkbox: CellCheckboxState?
    /// 二进制识别结果（用于快速查看与「图片 PNG」文案）。
    public var binaryFormat: BinaryFormatInfo?
    /// 已修改 / 新增 / 删除等状态的角标（T9 使用）。
    public var changeMarker: String?

    public init(
        text: String,
        isNull: Bool = false,
        isTruncated: Bool = false,
        alignment: CellAlignment = .leading,
        tooltip: String? = nil,
        checkbox: CellCheckboxState? = nil,
        binaryFormat: BinaryFormatInfo? = nil,
        changeMarker: String? = nil
    ) {
        self.text = text
        self.isNull = isNull
        self.isTruncated = isTruncated
        self.alignment = alignment
        self.tooltip = tooltip
        self.checkbox = checkbox
        self.binaryFormat = binaryFormat
        self.changeMarker = changeMarker
    }

    /// 用于剪贴板 / 快速查看标题的纯文本（不含展示用的 `«»`）。
    public var plainText: String { text }
}

/// 单元格显示规则的唯一实现，见 `specs/03-data-browsing.md` §4、`docs/tech-designs/07-data-grid.md` §4。
public enum CellDisplayFormatter {

    /// 单行化：把换行折叠成空格，避免单行控件里出现断裂。
    static func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    public static func display(
        value: SQLValue,
        isTruncated: Bool = false,
        totalByteCount: Int? = nil,
        column: ColumnInfo,
        context: CellDisplayContext = .default
    ) -> CellDisplay {
        let alignment = defaultAlignment(for: column, context: context)

        switch value {
        case .null:
            if context.tinyintAsCheckbox && column.isBooleanTinyInt {
                return CellDisplay(text: "", isNull: true, alignment: .center, checkbox: .mixed)
            }
            return CellDisplay(text: context.nullText, isNull: true, alignment: alignment)

        case .bool(let flag):
            if context.tinyintAsCheckbox && column.isBooleanTinyInt {
                return CellDisplay(text: "", alignment: .center, checkbox: flag ? .on : .off)
            }
            return CellDisplay(text: flag ? "1" : "0", alignment: alignment)

        case .integer(let number):
            return CellDisplay(text: String(number), alignment: alignment)

        case .decimal(let text):
            return CellDisplay(text: text, alignment: alignment)

        case .binary(let data):
            return binaryDisplay(data, isTruncated: isTruncated, totalByteCount: totalByteCount, column: column, context: context)

        case .text(let text):
            if context.tinyintAsCheckbox && column.isBooleanTinyInt {
                // `0` / `1` 三态：其它值按普通文本显示。
                if text == "0" { return CellDisplay(text: "", alignment: .center, checkbox: .off) }
                if text == "1" { return CellDisplay(text: "", alignment: .center, checkbox: .on) }
            }
            var display = singleLine(text)
            var tooltip: String? = nil
            if isTruncated {
                display += "…"
                tooltip = truncatedTooltip(totalByteCount: totalByteCount)
            }
            return CellDisplay(text: display, isTruncated: isTruncated, alignment: alignment, tooltip: tooltip)
        }
    }

    static func binaryDisplay(
        _ data: Data,
        isTruncated: Bool,
        totalByteCount: Int?,
        column: ColumnInfo,
        context: CellDisplayContext
    ) -> CellDisplay {
        let byteCount = totalByteCount ?? data.count
        let size = ByteSize.format(byteCount)
        var tooltip: String? = nil
        if isTruncated { tooltip = truncatedTooltip(totalByteCount: totalByteCount) }

        // 几何类型固定按 GEOMETRY 展示。
        if column.fieldType == .geometry {
            return CellDisplay(text: "«GEOMETRY \(size)»", isTruncated: isTruncated, alignment: .leading, tooltip: tooltip)
        }

        let format = BinaryFormatDetector.detect(data)
        if format.isImage {
            return CellDisplay(
                text: "«图片 \(format.displayName) \(size)»",
                isTruncated: isTruncated,
                alignment: .leading,
                tooltip: tooltip,
                binaryFormat: format
            )
        }

        if !isTruncated, data.count <= context.shortBinaryLimit {
            let hex = data.isEmpty ? "0x" : "0x" + data.hexString
            return CellDisplay(text: hex, alignment: .leading, tooltip: tooltip, binaryFormat: format)
        }

        return CellDisplay(
            text: "«BLOB \(size)»",
            isTruncated: isTruncated,
            alignment: .leading,
            tooltip: tooltip,
            binaryFormat: format
        )
    }

    static func truncatedTooltip(totalByteCount: Int?) -> String {
        if let total = totalByteCount {
            return "原始内容 \(ByteSize.format(total))，点开可查看完整内容"
        }
        return "内容已截断，点开可查看完整内容"
    }

    static func defaultAlignment(for column: ColumnInfo, context: CellDisplayContext) -> CellAlignment {
        if context.tinyintAsCheckbox && column.isBooleanTinyInt { return .center }
        if column.isNumeric && !column.isBooleanTinyInt { return .trailing }
        return .leading
    }

    // MARK: 快速查看

    /// 快速查看使用的呈现方式。见 `specs/03-data-browsing.md` §8。
    public static func quickLookKind(for column: ColumnInfo, value: SQLValue) -> QuickLookKind {
        switch value {
        case .binary(let data):
            return BinaryFormatDetector.detect(data).isImage ? .image : .binary
        case .text:
            if column.fieldType == .json || column.dataType?.lowercased() == "json" {
                return .json
            }
            if column.isLargeObject || column.isTemporal {
                return .text
            }
            return .text
        default:
            return .text
        }
    }
}

// MARK: - 十六进制预览

/// 生成快速查看用的十六进制 dump。纯函数，见 `specs/03-data-browsing.md` §8。
enum HexDump {
    /// 每行 16 字节。
    static func format(_ data: Data, limit: Int = 64 * 1024) -> String {
        let bytes = [UInt8](data.prefix(limit))
        guard !bytes.isEmpty else { return "（空）" }
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 16, bytes.count)
            let slice = bytes[offset..<end]
            let address = String(format: "%08X", offset)
            var hex = ""
            var ascii = ""
            for (index, byte) in slice.enumerated() {
                hex += String(format: "%02X ", byte)
                if index == 7 { hex += " " }
                ascii.append((byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : ".")
            }
            let paddedHex = hex.padding(toLength: 16 * 3 + 1, withPad: " ", startingAt: 0)
            lines.append("\(address)  \(paddedHex) \(ascii)")
            offset = end
        }
        if data.count > limit { lines.append("…") }
        return lines.joined(separator: "\n")
    }
}

/// 快速查看的呈现类型。
public enum QuickLookKind: Sendable, Equatable {
    case text
    case json
    case binary
    case image

    public var displayName: String {
        switch self {
        case .text: return "长文本"
        case .json: return "JSON"
        case .binary: return "二进制"
        case .image: return "图片"
        }
    }
}

// MARK: - 列类型文案

extension ColumnInfo {
    /// 字段栏里显示的完整类型文本（`varchar(255)` / `int unsigned` / `decimal(10,2)`）。
    public var typeDisplayText: String {
        if let columnTypeText, !columnTypeText.isEmpty { return columnTypeText }
        if let dataType, !dataType.isEmpty { return dataType }
        return String(describing: fieldType)
    }

    /// 列头 / 字段的悬停提示：`` `content` LONGTEXT NULL ``。
    public var gridTypeTooltip: String {
        let type = typeDisplayText.uppercased()
        let nullable = (isNullable == false) ? "NOT NULL" : "NULL"
        return "`\(name)` \(type) \(nullable)"
    }
}
