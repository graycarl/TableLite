import Foundation

// MARK: - CSV 编解码
//
// 纯逻辑，可单元测试。**不引入第三方 CSV / 编码库**。
// 规则见 docs/tech-designs/11-schema-and-import-export.md §2。
enum CSVCodec {

    /// 导出 / 解析选项。与偏好设置 `Preferences.cs*` 一一对应。
    struct Options: Hashable, Sendable {
        var delimiter: Character = ","
        var lineEnding: CSVLineEnding = .lf
        var includeHeader: Bool = true
        var encoding: CSVEncoding = .utf8
        var nullStyle: CSVNullStyle = .empty
    }

    // MARK: - 写（docs/11 §2.1）

    /// 需要加引号：含分隔符 / 引号 / 换行 / 首尾空格；引号内引号 → `""`。
    static func encodeField(_ text: String, delimiter: Character) -> String {
        let needsQuote = text.contains(delimiter)
            || text.contains("\"")
            || text.contains("\n")
            || text.contains("\r")
            || text.first.map(\.isWhitespace) == true
            || text.last.map(\.isWhitespace) == true
        guard needsQuote else { return text }
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// 一行（不含换行）。
    static func encodeRow(_ fields: [String], delimiter: Character) -> String {
        fields.map { encodeField($0, delimiter: delimiter) }.joined(separator: String(delimiter))
    }

    /// `CellValue` → 导出文本。
    ///
    /// - `NULL` 按 `nullStyle` 输出空串或 `NULL` 字面量；
    /// - 二进制家族（或内容不是合法 UTF-8）→ `0x…` 大写 hex；
    /// - 其它原样输出，浮点沿用服务器返回的原始文本，不重新格式化。
    static func exportText(_ value: CellValue, column: ResultSetColumn?, nullStyle: CSVNullStyle) -> String {
        exportText(value, isBinary: column?.kind.isBinaryLike == true, nullStyle: nullStyle)
    }

    /// 同 `exportText(_:column:nullStyle:)`，但二进制判定由调用方显式给出。
    ///
    /// 流式导出时逐行值不带列元数据，必须由导出源把列类型传进来，
    /// 否则「字节恰好是合法 UTF-8」的二进制列会被当成文本输出（见 docs/11 §2.1）。
    static func exportText(_ value: CellValue, isBinary: Bool, nullStyle: CSVNullStyle) -> String {
        switch value {
        case .null:
            return nullStyle == .literalNULL ? "NULL" : ""
        case .bytes(let bytes):
            if isBinary {
                return hexText(bytes)
            }
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                // 非法 UTF-8 → 按二进制处理，避免损坏数据
                return hexText(bytes)
            }
            return text
        }
    }

    /// UTF-8 BOM；其它编码为空。
    static func byteOrderMark(for encoding: CSVEncoding) -> [UInt8] {
        switch encoding {
        case .utf8: return []
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        }
    }

    // MARK: - 读（docs/11 §2.2）

    struct ParseResult: Hashable, Sendable {
        var rows: [[String]]
        var detectedDelimiter: Character
        var detectedEncoding: String
    }

    enum ParseError: Error, Hashable, Sendable {
        case emptyFile
        case unclosedQuote(row: Int)
        case inconsistentColumns(row: Int, expected: Int, actual: Int)
        case undecodableText
    }

    /// 解析 CSV 字节。编码自动检测；`delimiter == nil` 时自动检测分隔符。
    ///
    /// 覆盖边界见 docs/11 §2.2：引号内分隔符 / 换行不切分；`""` 还原一个引号；
    /// 字段首尾空格保留；列数少于表头补空、多于表头报错并给行号；去 BOM；
    /// 兼容 CRLF / LF / CR；末行无换行仍读取；空文件报错；引号未闭合报错并给行号。
    static func parse(_ data: Data, delimiter: Character?) throws -> ParseResult {
        guard !data.isEmpty else { throw ParseError.emptyFile }
        guard let encodingName = detectEncoding(data),
              var text = decode(data, as: encodingName) else {
            throw ParseError.undecodableText
        }
        // 去掉 UTF-8 BOM（Foundation 一般已剥掉，这里兜底）
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let resolvedDelimiter = delimiter ?? detectDelimiter(text)
        var rows = try splitRecords(text, delimiter: resolvedDelimiter)
        guard !rows.isEmpty else { throw ParseError.emptyFile }

        // 列数一致性：以首行（表头）为准。
        let expected = rows[0].count
        for index in 1..<rows.count {
            let actual = rows[index].count
            if actual < expected {
                rows[index].append(contentsOf: Array(repeating: "", count: expected - actual))
            } else if actual > expected {
                throw ParseError.inconsistentColumns(row: index + 1, expected: expected, actual: actual)
            }
        }

        return ParseResult(rows: rows,
                           detectedDelimiter: resolvedDelimiter,
                           detectedEncoding: encodingName)
    }

    /// 编码检测。顺序：UTF-8 严格 → GB18030 → 带 BOM 的 UTF-16 → 失败 nil。
    static func detectEncoding(_ data: Data) -> String? {
        if String(data: data, encoding: .utf8) != nil { return "UTF-8" }
        if String(data: data, encoding: gb18030Encoding) != nil { return "GB18030" }
        if hasUTF16BOM(data) { return "UTF-16" }
        return nil
    }

    /// 读前 5 行统计候选分隔符（`,` `\t` `;` `|`）的出现稳定性；失败用逗号。
    ///
    /// 稳定性 = 每个非空行中该分隔符出现次数一致且 > 0；平局时按候选顺序优先逗号。
    static func detectDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", "\t", ";", "|"]
        let lines = text
            .split(whereSeparator: { isLineBreak($0) })
            .filter { !$0.isEmpty }
            .prefix(5)
            .map(String.init)
        guard !lines.isEmpty else { return "," }

        var best: Character = ","
        var bestCount = 0
        for candidate in candidates {
            let counts = lines.map { countUnquoted($0, delimiter: candidate) }
            guard let first = counts.first, first > 0 else { continue }
            guard counts.allSatisfy({ $0 == first }) else { continue }
            if first > bestCount {
                bestCount = first
                best = candidate
            }
        }
        return best
    }

    // MARK: - 内部：字节 / 编码

    /// GB18030（覆盖 GBK / GB2312）。
    private static let gb18030Encoding: String.Encoding = {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }()

    private static func hasUTF16BOM(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let start = data.startIndex
        let b0 = data[start]
        let b1 = data[data.index(after: start)]
        return (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF)
    }

    private static func decode(_ data: Data, as name: String) -> String? {
        switch name {
        case "UTF-8": return String(data: data, encoding: .utf8)
        case "GB18030": return String(data: data, encoding: gb18030Encoding)
        case "UTF-16": return String(data: data, encoding: .utf16)
        default: return nil
        }
    }

    private static func hexText(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "0x" }
        var output = "0x"
        output.reserveCapacity(2 + bytes.count * 2)
        for byte in bytes {
            let hex = String(byte, radix: 16, uppercase: true)
            output += hex.count == 1 ? "0" + hex : hex
        }
        return output
    }

    // MARK: - 内部：状态机

    /// 状态机解析：`""` 转义、引号内分隔符 / 换行不切分、CRLF / LF / CR 均识别。
    private static func splitRecords(_ text: String, delimiter: Character) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var pending = false

        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if inQuotes {
                if char == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                    } else {
                        inQuotes = false
                        index += 1
                    }
                } else {
                    field.append(char)
                    index += 1
                }
                continue
            }

            if char == "\"" && field.isEmpty {
                inQuotes = true
                pending = true
                index += 1
            } else if char == delimiter {
                row.append(field)
                field = ""
                pending = true
                index += 1
            } else if isLineBreak(char) {
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                pending = false
                if char == "\r", index + 1 < chars.count, chars[index + 1] == "\n" {
                    index += 2
                } else {
                    index += 1
                }
            } else {
                field.append(char)
                pending = true
                index += 1
            }
        }

        if inQuotes {
            // 引号未闭合：报当前正在构造的记录号（1-based）
            throw ParseError.unclosedQuote(row: rows.count + 1)
        }
        // 末行无换行仍读取；末尾换行不产生额外的空记录
        if pending {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// 换行界定。注意 Swift 的 `Character` 会把 `\r\n` 当作**一个**字素簇，必须单独匹配。
    private static func isLineBreak(_ char: Character) -> Bool {
        char == "\n" || char == "\r" || char == "\r\n"
    }

    /// 统计一行中不在引号内的分隔符数量（用于检测）。
    private static func countUnquoted(_ line: String, delimiter: Character) -> Int {
        var count = 0
        var inQuotes = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if inQuotes, index + 1 < chars.count, chars[index + 1] == "\"" {
                    index += 2
                    continue
                }
                inQuotes.toggle()
                index += 1
            } else if char == delimiter && !inQuotes {
                count += 1
                index += 1
            } else {
                index += 1
            }
        }
        return count
    }
}
