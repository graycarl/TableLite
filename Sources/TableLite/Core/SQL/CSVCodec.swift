import Foundation
import CoreFoundation

// MARK: - CSV 值

/// 导出时一个字段的值。
public enum CSVField: Sendable, Equatable, Hashable {
    case text(String)
    case null
    case binary(Data)

    public init(_ value: SQLValue) {
        switch value {
        case .null:
            self = .null
        case .binary(let data):
            self = .binary(data)
        case .text(let text):
            self = .text(text)
        case .integer(let number):
            self = .text(String(number))
        case .decimal(let text):
            self = .text(text)
        case .bool(let flag):
            self = .text(flag ? "1" : "0")
        }
    }
}

public enum CSVLineEnding: String, Sendable, Equatable, Hashable, CaseIterable {
    case lf
    case crlf

    public var bytes: [UInt8] {
        switch self {
        case .lf: return [0x0A]
        case .crlf: return [0x0D, 0x0A]
        }
    }

    public var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        }
    }
}

/// 输出文本编码。导出面板只提供 UTF-8 / UTF-8 BOM（`specs/08-import-export.md` §1）。
public enum CSVTextEncoding: String, Sendable, Equatable, Hashable, CaseIterable {
    case utf8
    case utf8WithBOM

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8WithBOM: return "UTF-8 BOM"
        }
    }
}

/// 输入编码。`auto` 表示按 UTF-8 → GB18030 → 带 BOM 的 UTF-16 顺序检测。
public enum CSVInputEncoding: String, Sendable, Equatable, Hashable, CaseIterable {
    case auto
    case utf8
    case utf8WithBOM
    case gb18030
    case utf16LittleEndian
    case utf16BigEndian

    public var displayName: String {
        switch self {
        case .auto: return "自动检测"
        case .utf8: return "UTF-8"
        case .utf8WithBOM: return "UTF-8 BOM"
        case .gb18030: return "GB18030"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        }
    }
}

/// `NULL` 的表示方式。默认空字符串。
public enum CSVNullRepresentation: String, Sendable, Equatable, Hashable, CaseIterable {
    case emptyString
    case nullLiteral

    public var displayName: String {
        switch self {
        case .emptyString: return "空字符串"
        case .nullLiteral: return "NULL 字面量"
        }
    }
}

// MARK: - 选项与结果

public struct CSVWriteOptions: Sendable, Equatable {
    /// 分隔符字节，默认逗号。
    public var delimiter: UInt8
    public var lineEnding: CSVLineEnding
    public var includeHeader: Bool
    public var encoding: CSVTextEncoding
    public var nullRepresentation: CSVNullRepresentation

    public init(
        delimiter: UInt8 = 0x2C,
        lineEnding: CSVLineEnding = .lf,
        includeHeader: Bool = true,
        encoding: CSVTextEncoding = .utf8,
        nullRepresentation: CSVNullRepresentation = .emptyString
    ) {
        self.delimiter = delimiter
        self.lineEnding = lineEnding
        self.includeHeader = includeHeader
        self.encoding = encoding
        self.nullRepresentation = nullRepresentation
    }

    public static let `default` = CSVWriteOptions()
}

public struct CSVParseOptions: Sendable, Equatable {
    /// nil 表示自动检测。
    public var delimiter: UInt8?
    public var hasHeader: Bool
    public var encoding: CSVInputEncoding

    public init(delimiter: UInt8? = nil, hasHeader: Bool = true, encoding: CSVInputEncoding = .auto) {
        self.delimiter = delimiter
        self.hasHeader = hasHeader
        self.encoding = encoding
    }

    public static let `default` = CSVParseOptions()
}

/// 一条解析出来的记录。
public struct CSVRecord: Sendable, Equatable, Hashable {
    public var fields: [String]
    /// 记录起始行号（1-based）。
    public var lineNumber: Int

    public init(fields: [String], lineNumber: Int) {
        self.fields = fields
        self.lineNumber = lineNumber
    }
}

public struct CSVParseResult: Sendable, Equatable {
    public var header: [String]?
    public var records: [CSVRecord]
    public var encoding: CSVInputEncoding
    public var delimiter: UInt8
    /// 分隔符是检测出来的还是回退到逗号。
    public var delimiterWasDetected: Bool

    public init(
        header: [String]?,
        records: [CSVRecord],
        encoding: CSVInputEncoding,
        delimiter: UInt8,
        delimiterWasDetected: Bool
    ) {
        self.header = header
        self.records = records
        self.encoding = encoding
        self.delimiter = delimiter
        self.delimiterWasDetected = delimiterWasDetected
    }
}

public enum CSVParseError: Error, Sendable, Equatable {
    case emptyFile
    case unclosedQuote(line: Int)
    case columnCountMismatch(line: Int, expected: Int, actual: Int)
    case unsupportedEncoding

    public var message: String {
        switch self {
        case .emptyFile: return "文件为空，没有可导入的内容"
        case .unclosedQuote(let line): return "第 \(line) 行的引号没有闭合"
        case .columnCountMismatch(let line, let expected, let actual):
            return "第 \(line) 行有 \(actual) 列，与表头的 \(expected) 列不一致"
        case .unsupportedEncoding: return "无法识别文件编码，请手动选择"
        }
    }
}

// MARK: - 编解码

/// CSV 编解码。规则见 `docs/tech-designs/11-schema-and-import-export.md` §2。
///
/// 纯函数，不依赖任何连接；写用缓冲拼接，读用一次性解析（流式导入由上层按块调用）。
public enum CSVCodec {
    public static let comma: UInt8 = 0x2C
    public static let tab: UInt8 = 0x09
    public static let semicolon: UInt8 = 0x3B
    public static let pipe: UInt8 = 0x7C
    public static let quote: UInt8 = 0x22

    // MARK: 写

    /// 生成 CSV 文本（不含 BOM）。
    public static func encodeString(
        header: [String]?,
        rows: [[CSVField]],
        options: CSVWriteOptions = .default
    ) -> String {
        var lines: [String] = []
        if options.includeHeader, let header {
            lines.append(header.map { encodeField(.text($0), options: options) }.joined(separator: delimiterString(options.delimiter)))
        }
        for row in rows {
            lines.append(row.map { encodeField($0, options: options) }.joined(separator: delimiterString(options.delimiter)))
        }
        let lineEnding = options.lineEnding == .crlf ? "\r\n" : "\n"
        var text = lines.joined(separator: lineEnding)
        if !lines.isEmpty { text += lineEnding }
        return text
    }

    /// 生成 CSV 字节，按选项加 BOM。
    public static func encode(
        header: [String]?,
        rows: [[CSVField]],
        options: CSVWriteOptions = .default
    ) -> Data {
        let text = encodeString(header: header, rows: rows, options: options)
        var data = Data()
        if options.encoding == .utf8WithBOM {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: text.utf8)
        return data
    }

    /// 编码单个字段。
    public static func encodeField(_ field: CSVField, options: CSVWriteOptions = .default) -> String {
        switch field {
        case .null:
            switch options.nullRepresentation {
            case .emptyString: return ""
            case .nullLiteral: return "NULL"
            }
        case .binary(let data):
            return quoteIfNeeded(SQLValueLiteral.hexLiteral(data), delimiter: options.delimiter)
        case .text(let text):
            return quoteIfNeeded(text, delimiter: options.delimiter)
        }
    }

    /// 是否需要加引号：含分隔符、引号、换行或首尾空格。
    public static func needsQuoting(_ text: String, delimiter: UInt8) -> Bool {
        if text.isEmpty { return false }
        if text.first == " " || text.last == " " { return true }
        let delimiterCharacter = Character(UnicodeScalar(delimiter))
        for character in text {
            if character == delimiterCharacter || character == "\"" || character == "\n" || character == "\r" {
                return true
            }
        }
        return false
    }

    static func quoteIfNeeded(_ text: String, delimiter: UInt8) -> String {
        guard needsQuoting(text, delimiter: delimiter) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func delimiterString(_ delimiter: UInt8) -> String {
        String(UnicodeScalar(delimiter))
    }

    // MARK: 读

    public static func parse(
        data: Data,
        options: CSVParseOptions = .default
    ) throws -> CSVParseResult {
        let (text, encoding) = try decode(data: data, requested: options.encoding)
        return try parse(text: text, detectedEncoding: encoding, options: options)
    }

    public static func parse(
        text: String,
        detectedEncoding: CSVInputEncoding = .utf8,
        options: CSVParseOptions = .default
    ) throws -> CSVParseResult {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { throw CSVParseError.emptyFile }

        let delimiterWasDetected: Bool
        let delimiter: UInt8
        if let explicit = options.delimiter {
            delimiter = explicit
            delimiterWasDetected = true
        } else {
            let detected = detectDelimiter(bytes)
            delimiter = detected.delimiter
            delimiterWasDetected = detected.detected
        }

        let parsed = try parseRecords(bytes, delimiter: delimiter)
        let allRecords = parsed
        guard !allRecords.isEmpty else { throw CSVParseError.emptyFile }

        let header: [String]?
        let dataRecords: [CSVRecord]
        if options.hasHeader {
            header = allRecords[0].fields
            dataRecords = Array(allRecords.dropFirst())
        } else {
            header = nil
            dataRecords = allRecords
        }

        // 列数校验：少于表头补空，多于表头报错并给出行号。
        let expected = header?.count ?? dataRecords.first?.fields.count ?? 0
        let normalized = try dataRecords.map { record -> CSVRecord in
            if record.fields.count > expected {
                throw CSVParseError.columnCountMismatch(
                    line: record.lineNumber,
                    expected: expected,
                    actual: record.fields.count
                )
            }
            if record.fields.count < expected {
                var fields = record.fields
                fields.append(contentsOf: Array(repeating: "", count: expected - fields.count))
                return CSVRecord(fields: fields, lineNumber: record.lineNumber)
            }
            return record
        }

        return CSVParseResult(
            header: header,
            records: normalized,
            encoding: detectedEncoding,
            delimiter: delimiter,
            delimiterWasDetected: delimiterWasDetected
        )
    }

    // MARK: 编码检测

    static func decode(data: Data, requested: CSVInputEncoding) throws -> (String, CSVInputEncoding) {
        switch requested {
        case .utf8WithBOM:
            guard data.count >= 3, data[data.startIndex] == 0xEF,
                  data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF else {
                throw CSVParseError.unsupportedEncoding
            }
            let body = data.subdata(in: (data.startIndex + 3)..<data.endIndex)
            guard let text = String(data: body, encoding: .utf8) else {
                throw CSVParseError.unsupportedEncoding
            }
            return (text, .utf8WithBOM)

        case .utf8:
            guard let text = String(data: data, encoding: .utf8) else {
                throw CSVParseError.unsupportedEncoding
            }
            return (text, .utf8)

        case .gb18030:
            guard let text = String(data: data, encoding: Self.gb18030) else {
                throw CSVParseError.unsupportedEncoding
            }
            return (text, .gb18030)

        case .utf16LittleEndian:
            let body = stripBOM(data, littleEndian: true)
            guard let text = String(data: body, encoding: .utf16LittleEndian) else {
                throw CSVParseError.unsupportedEncoding
            }
            return (text, .utf16LittleEndian)

        case .utf16BigEndian:
            let body = stripBOM(data, littleEndian: false)
            guard let text = String(data: body, encoding: .utf16BigEndian) else {
                throw CSVParseError.unsupportedEncoding
            }
            return (text, .utf16BigEndian)

        case .auto:
            // 1. BOM
            if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE {
                let body = data.subdata(in: (data.startIndex + 2)..<data.endIndex)
                if let text = String(data: body, encoding: .utf16LittleEndian) {
                    return (text, .utf16LittleEndian)
                }
            }
            if data.count >= 2, data[data.startIndex] == 0xFE, data[data.startIndex + 1] == 0xFF {
                let body = data.subdata(in: (data.startIndex + 2)..<data.endIndex)
                if let text = String(data: body, encoding: .utf16BigEndian) {
                    return (text, .utf16BigEndian)
                }
            }
            if data.count >= 3, data[data.startIndex] == 0xEF,
               data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF {
                let body = data.subdata(in: (data.startIndex + 3)..<data.endIndex)
                if let text = String(data: body, encoding: .utf8) {
                    return (text, .utf8WithBOM)
                }
            }
            // 2. UTF-8 严格
            if let text = String(data: data, encoding: .utf8) {
                return (text, .utf8)
            }
            // 3. GB18030
            if let text = String(data: data, encoding: Self.gb18030) {
                return (text, .gb18030)
            }
            throw CSVParseError.unsupportedEncoding
        }
    }

    static func stripBOM(_ data: Data, littleEndian: Bool) -> Data {
        guard data.count >= 2 else { return data }
        if littleEndian, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE {
            return data.subdata(in: (data.startIndex + 2)..<data.endIndex)
        }
        if !littleEndian, data[data.startIndex] == 0xFE, data[data.startIndex + 1] == 0xFF {
            return data.subdata(in: (data.startIndex + 2)..<data.endIndex)
        }
        return data
    }

    static let gb18030: String.Encoding = {
        let cfEncoding = CFStringEncodings.GB_18030_2000.rawValue
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding)))
    }()

    // MARK: 分隔符检测

    /// 读前 5 条记录统计候选分隔符的稳定性。
    static func detectDelimiter(_ bytes: [UInt8]) -> (delimiter: UInt8, detected: Bool) {
        let candidates: [UInt8] = [comma, tab, semicolon, pipe]
        var best: (delimiter: UInt8, score: Int)?

        for candidate in candidates {
            let counts = fieldCounts(bytes, delimiter: candidate, maxRecords: 5)
            guard !counts.isEmpty else { continue }
            let stable = counts.allSatisfy { $0 == counts[0] }
            let maxCount = counts.max() ?? 0
            guard maxCount > 1 else { continue }

            // 稳定优先，其次列数多者优先。
            let score = (stable ? 1000 : 0) + maxCount
            if let current = best {
                if score > current.score {
                    best = (candidate, score)
                }
            } else {
                best = (candidate, score)
            }
        }

        guard let best else { return (comma, false) }
        let counts = fieldCounts(bytes, delimiter: best.delimiter, maxRecords: 5)
        let stable = counts.allSatisfy { $0 == counts[0] } && counts[0] > 1
        return (best.delimiter, stable)
    }

    /// 用给定分隔符数出前若干条记录的字段数（忽略引号内的分隔符）。
    static func fieldCounts(_ bytes: [UInt8], delimiter: UInt8, maxRecords: Int) -> [Int] {
        var counts: [Int] = []
        var fields = 1
        var inQuotes = false
        var index = 0
        while index < bytes.count, counts.count < maxRecords {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < bytes.count, bytes[index + 1] == quote {
                        index += 2
                        continue
                    }
                    inQuotes = false
                }
                index += 1
                continue
            }
            if byte == quote {
                inQuotes = true
                index += 1
                continue
            }
            if byte == delimiter {
                fields += 1
            } else if byte == 0x0A || byte == 0x0D {
                counts.append(fields)
                fields = 1
                if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 1
                }
            }
            index += 1
        }
        if fields > 1 || counts.isEmpty {
            counts.append(fields)
        }
        return counts
    }

    // MARK: 记录解析

    static func parseRecords(
        _ bytes: [UInt8],
        delimiter: UInt8
    ) throws -> [CSVRecord] {
        var records: [CSVRecord] = []
        var fieldBytes: [UInt8] = []
        var fields: [String] = []
        var inQuotes = false
        var line = 1
        var recordStartLine = 1
        var sawAnyContent = false
        var index = 0

        func flushField() {
            fields.append(String(decoding: fieldBytes, as: UTF8.self))
            fieldBytes.removeAll(keepingCapacity: true)
        }

        func flushRecord() {
            flushField()
            records.append(CSVRecord(fields: fields, lineNumber: recordStartLine))
            fields.removeAll(keepingCapacity: true)
        }

        while index < bytes.count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < bytes.count, bytes[index + 1] == quote {
                        fieldBytes.append(quote)
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                if byte == 0x0A {
                    line += 1
                } else if byte == 0x0D {
                    line += 1
                    if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                        fieldBytes.append(byte)
                        index += 1
                        fieldBytes.append(bytes[index])
                        index += 1
                        continue
                    }
                }
                fieldBytes.append(byte)
                index += 1
                continue
            }

            if byte == quote, fieldBytes.isEmpty {
                inQuotes = true
                sawAnyContent = true
                index += 1
                continue
            }
            if byte == delimiter {
                flushField()
                sawAnyContent = true
                index += 1
                continue
            }
            if byte == 0x0A || byte == 0x0D {
                flushRecord()
                sawAnyContent = true
                line += 1
                if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 1
                }
                index += 1
                recordStartLine = line
                continue
            }
            fieldBytes.append(byte)
            sawAnyContent = true
            index += 1
        }

        if inQuotes {
            throw CSVParseError.unclosedQuote(line: recordStartLine)
        }
        // 末行没有换行仍要被读取。
        if !fieldBytes.isEmpty || !fields.isEmpty {
            flushRecord()
        }
        if !sawAnyContent {
            return []
        }
        return records
    }
}
