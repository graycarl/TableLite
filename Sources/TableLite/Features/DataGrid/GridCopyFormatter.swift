import Foundation

// MARK: - 复制格式
//
// 「复制为…」的全部输出都在这里，纯函数、无 IO、可单元测试。
// 需求见 specs/03-data-browsing.md §9，规则见 docs/tech-designs/07-data-grid.md §8。
//
// 复制用的值来自数据网格的「当前显示值」（已合并暂存区里的修改）。
// SQL INSERT 复用 `SQLValueLiteral`，与提交语句的字面量规则完全一致。
//
// 约定：
// - SQL NULL 在纯文本 / TSV / 列 / Markdown / CSV 里用用户偏好里的 `nullText` 表示；
//   在 JSON 里用 JSON 的 `null`；在 SQL INSERT 里用 `NULL`。
// - 二进制与非法 UTF-8 一律输出 `0x` 大写 hex。
// - 截断的大字段**不进入 SQL INSERT**（避免把截断前缀写进可执行语句），
//   与 docs/tech-designs/08-pending-changes.md §9 的安全保证一致。
enum GridCopyFormatter {

    // MARK: - 纯文本 / TSV

    /// 单元格的纯文本。
    static func cellText(_ value: CellValue, column: TableColumn?, nullText: String) -> String {
        switch value {
        case .null:
            return nullText
        case .bytes(let bytes):
            if column?.kind.isBinaryLike == true {
                return SQLValueLiteral.hexLiteral(bytes)
            }
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                return SQLValueLiteral.hexLiteral(bytes)
            }
            return text
        }
    }

    /// 一行，制表符分隔。
    static func rowText(_ row: TableDataRow, columns: [TableColumn], nullText: String) -> String {
        columns.enumerated().map { index, column in
            cellText(value(at: index, in: row), column: column, nullText: nullText)
        }.joined(separator: "\t")
    }

    /// 多行，制表符分隔。
    static func rowsText(_ rows: [TableDataRow], columns: [TableColumn], nullText: String) -> String {
        rows.map { rowText($0, columns: columns, nullText: nullText) }.joined(separator: "\n")
    }

    /// 整列的值，每行一个。
    static func columnText(_ rows: [TableDataRow], column: TableColumn, index: Int, nullText: String) -> String {
        rows.map { cellText(value(at: index, in: $0), column: column, nullText: nullText) }
            .joined(separator: "\n")
    }

    /// 列名，逗号分隔。
    static func columnNames(_ columns: [TableColumn]) -> String {
        columns.map(\.name).joined(separator: ", ")
    }

    // MARK: - JSON

    /// JSON 数组；每个对象以列名为键。数值列输出 JSON 数字，布尔列输出 true/false，其余为字符串。
    static func json(_ rows: [TableDataRow], columns: [TableColumn]) -> String {
        let objects = rows.map { row -> String in
            let pairs = columns.enumerated().map { index, column -> String in
                let key = jsonString(column.name)
                let value = jsonValue(value(at: index, in: row), column: column)
                return "  \(key): \(value)"
            }
            return "{\n" + pairs.joined(separator: ",\n") + "\n}"
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    /// 单个值的 JSON 表示（供 json 使用，独立可测）。
    static func jsonValue(_ value: CellValue, column: TableColumn) -> String {
        switch value {
        case .null:
            return "null"
        case .bytes(let bytes):
            if column.kind.isBinaryLike {
                return jsonString(SQLValueLiteral.hexLiteral(bytes))
            }
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                return jsonString(SQLValueLiteral.hexLiteral(bytes))
            }
            switch column.kind {
            case .boolean where text == "0" || text == "1":
                return text == "1" ? "true" : "false"
            default:
                if column.kind.isNumeric, SQLValueLiteral.isStrictNumeric(text) {
                    return text
                }
                return jsonString(text)
            }
        }
    }

    /// JSON 字符串转义（含控制字符与常见转义）。
    static func jsonString(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }

    // MARK: - Markdown

    /// Markdown 表格（带表头与分隔线）。`|` 转义、换行变 `<br>`。
    static func markdown(_ rows: [TableDataRow], columns: [TableColumn], nullText: String) -> String {
        var lines: [String] = []
        lines.append("| " + columns.map { markdownCell($0.name) }.joined(separator: " | ") + " |")
        lines.append("| " + columns.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows {
            let cells = columns.enumerated().map { index, column in
                markdownCell(cellText(value(at: index, in: row), column: column, nullText: nullText))
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown 单元格转义。
    static func markdownCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    // MARK: - CSV

    /// CSV（`CSVCodec` 负责引号规则）。
    static func csv(_ rows: [TableDataRow],
                    columns: [TableColumn],
                    delimiter: Character,
                    includeHeader: Bool,
                    nullStyle: CSVNullStyle) -> String {
        var lines: [String] = []
        if includeHeader {
            lines.append(CSVCodec.encodeRow(columns.map(\.name), delimiter: delimiter))
        }
        for row in rows {
            let fields = columns.enumerated().map { index, column -> String in
                csvField(value(at: index, in: row), column: column, nullStyle: nullStyle)
            }
            lines.append(CSVCodec.encodeRow(fields, delimiter: delimiter))
        }
        return lines.joined(separator: "\n")
    }

    /// 单个 CSV 字段的文本（不含引号）。
    static func csvField(_ value: CellValue, column: TableColumn, nullStyle: CSVNullStyle) -> String {
        switch value {
        case .null:
            return nullStyle == .literalNULL ? "NULL" : ""
        case .bytes(let bytes):
            if column.kind.isBinaryLike {
                return SQLValueLiteral.hexLiteral(bytes)
            }
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                return SQLValueLiteral.hexLiteral(bytes)
            }
            return text
        }
    }

    // MARK: - SQL

    /// SQL INSERT，一行一条，可直接执行。
    ///
    /// 截断且未加载完整值的大字段会被**跳过**（不写入），避免把 `LEFT(col, N)` 的截断前缀
    /// 当成真实内容写进数据库。全部列都被跳过时生成 `INSERT INTO t () VALUES ();`。
    static func sqlInsert(ref: TableRef,
                          rows: [TableDataRow],
                          columns: [TableColumn],
                          using literalizer: SQLValueLiteralizer) -> String {
        guard !rows.isEmpty else { return "" }
        let retained = columns.enumerated().filter { index, column in
            !isTruncated(column: column, at: index, in: rows)
        }
        let table = SQLIdentifier.qualified(ref.database, ref.table)
        return rows.map { row -> String in
            let names = retained.map { SQLIdentifier.quote($0.element.name) }
            let values = retained.map { entry -> String in
                SQLValueLiteral.literal(value(at: entry.offset, in: row),
                                        kind: entry.element.kind,
                                        using: literalizer)
            }
            let columnList = names.joined(separator: ", ")
            let valueList = values.joined(separator: ", ")
            return "INSERT INTO \(table) (\(columnList)) VALUES (\(valueList));"
        }.joined(separator: "\n")
    }

    /// 建表语句（表结构复制）。原样返回，缺失时返回空串。
    static func createStatement(_ structure: TableStructure) -> String {
        structure.createStatement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 内部

    /// 任一行在该列上都是截断值才跳过（保守：只要有一行已加载完整就保留该列）。
    private static func isTruncated(column: TableColumn, at index: Int, in rows: [TableDataRow]) -> Bool {
        guard column.isLargeObject else { return false }
        return rows.allSatisfy { row in
            index < row.values.count && row.truncatedLengths[column.name] != nil
        }
    }

    /// 越界安全取值；缺失按 NULL。
    private static func value(at index: Int, in row: TableDataRow) -> CellValue {
        guard index >= 0, index < row.values.count else { return .null }
        return row.values[index]
    }
}

// MARK: - 单元格展示格式（纯函数）
//
// 网格与快速查看共用的二进制 / 图片 / 体积文案。见 specs/03-data-browsing.md §4。
enum GridValueFormatter {

    /// 短二进制的分界：不超过该字节数直接显示 `0x…`，超过则显示 `«BLOB x KB»`。
    static let shortBinaryByteLimit = 64

    /// `25 B` / `12.3 KB` / `1.2 MB` / `2.0 GB`（数字与单位之间加空格）。
    static func byteCount(_ count: Int) -> String {
        let value = max(count, 0)
        if value < 1024 { return "\(value) B" }
        let kb = Double(value) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.1f GB", gb)
    }

    /// 按魔数识别图片格式；不是图片返回 nil。
    static func imageFormat(_ bytes: [UInt8]) -> String? {
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + signature.count else { return false }
            return Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if starts([0xFF, 0xD8, 0xFF]) { return "JPEG" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "GIF" }
        if starts([0x42, 0x4D]) { return "BMP" }
        if starts([0x52, 0x49, 0x46, 0x46]), starts([0x57, 0x45, 0x42, 0x50], at: 8) { return "WEBP" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "TIFF" }
        return nil
    }

    /// 二进制单元格的占位文案：`«图片 PNG 45.2 KB»` / `«GEOMETRY 25 B»` / `«BLOB 12.3 KB»`；
    /// 短内容是直接可读的 hex（`0xDEADBEEF`）。
    static func binaryPlaceholder(kind: ColumnKind, bytes: [UInt8]) -> String {
        if let image = imageFormat(bytes) {
            return "«图片 \(image) \(byteCount(bytes.count))»"
        }
        if kind == .geometry {
            return "«GEOMETRY \(byteCount(bytes.count))»"
        }
        if bytes.count <= shortBinaryByteLimit {
            return SQLValueLiteral.hexLiteral(bytes)
        }
        return "«BLOB \(byteCount(bytes.count))»"
    }
}
