import Foundation

/// 复制格式。见 `docs/tech-designs/07-data-grid.md` §8、`specs/03-data-browsing.md` §9。
public enum CopyFormat: String, Sendable, Codable, CaseIterable, Hashable {
    case cellValue
    case row
    case rows
    case columnValues
    case columnNames
    case json
    case markdown
    case csv
    case csvWithHeader
    case sqlInsert

    public var displayName: String {
        switch self {
        case .cellValue: return "复制单元格值"
        case .row: return "复制行"
        case .rows: return "复制选中行"
        case .columnValues: return "复制整列的值"
        case .columnNames: return "复制列名"
        case .json: return "复制为 JSON"
        case .markdown: return "复制为 Markdown 表格"
        case .csv: return "复制为 CSV"
        case .csvWithHeader: return "复制为 CSV（含表头）"
        case .sqlInsert: return "复制为 SQL INSERT"
        }
    }
}

public struct CopyOptions: Sendable, Equatable {
    public var csvDelimiter: UInt8
    public var lineEnding: CSVLineEnding
    public var nullRepresentation: CSVNullRepresentation

    public init(
        csvDelimiter: UInt8 = CSVCodec.comma,
        lineEnding: CSVLineEnding = .lf,
        nullRepresentation: CSVNullRepresentation = .emptyString
    ) {
        self.csvDelimiter = csvDelimiter
        self.lineEnding = lineEnding
        self.nullRepresentation = nullRepresentation
    }

    public static let `default` = CopyOptions()
}

/// 把网格数据格式化成剪贴板文本。
public enum CopyFormatter {
    public static func format(
        rows: [[SQLValue]],
        columns: [ColumnInfo],
        format: CopyFormat,
        database: String? = nil,
        table: String? = nil,
        options: CopyOptions = .default
    ) -> String {
        switch format {
        case .cellValue:
            guard let first = rows.first?.first else { return "" }
            return text(of: first)

        case .row:
            guard let first = rows.first else { return "" }
            return first.map(text(of:)).joined(separator: "\t")

        case .rows:
            return rows.map { $0.map(text(of:)).joined(separator: "\t") }.joined(separator: newline(options))

        case .columnValues:
            return rows.compactMap { $0.first.map(text(of:)) }.joined(separator: newline(options))

        case .columnNames:
            return columns.map(\.name).joined(separator: ",")

        case .json:
            return json(rows: rows, columns: columns)

        case .markdown:
            return markdown(rows: rows, columns: columns)

        case .csv:
            return CSVCodec.encodeString(
                header: nil,
                rows: rows.map { $0.map(CSVField.init) },
                options: csvWriteOptions(options, includeHeader: false)
            )

        case .csvWithHeader:
            return CSVCodec.encodeString(
                header: columns.map(\.name),
                rows: rows.map { $0.map(CSVField.init) },
                options: csvWriteOptions(options, includeHeader: true)
            )

        case .sqlInsert:
            return sqlInsert(rows: rows, columns: columns, database: database, table: table)
        }
    }

    // MARK: 文本

    /// 纯文本表示：NULL 写 `NULL`，二进制写大写 hex。
    public static func text(of value: SQLValue) -> String {
        switch value {
        case .null: return "NULL"
        case .binary(let data): return data.hexString
        case .text(let text): return text
        case .integer(let number): return String(number)
        case .decimal(let text): return text
        case .bool(let flag): return flag ? "1" : "0"
        }
    }

    // MARK: JSON

    static func json(rows: [[SQLValue]], columns: [ColumnInfo]) -> String {
        let objects = rows.map { row -> String in
            let pairs = columns.enumerated().map { index, column -> String in
                let value = index < row.count ? row[index] : .null
                return "\(jsonString(column.name)): \(jsonValue(value, column: column))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        }
        return "[\(objects.joined(separator: ", "))]"
    }

    static func jsonValue(_ value: SQLValue, column: ColumnInfo) -> String {
        switch value {
        case .null: return "null"
        case .binary(let data): return jsonString("0x" + data.hexString)
        case .bool(let flag): return flag ? "true" : "false"
        case .integer(let number): return String(number)
        case .decimal(let text):
            return SQLValueLiteral.isStrictDecimal(text) ? text : jsonString(text)
        case .text(let text):
            if column.fieldType.isNumeric, SQLValueLiteral.isStrictNumber(text) {
                return text
            }
            return jsonString(text)
        }
    }

    static func jsonString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    // MARK: Markdown

    static func markdown(rows: [[SQLValue]], columns: [ColumnInfo]) -> String {
        let header = "| " + columns.map { escapeMarkdown($0.name) }.joined(separator: " | ") + " |"
        let separator = "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |"
        let body = rows.map { row -> String in
            let cells = columns.enumerated().map { index, _ -> String in
                let value = index < row.count ? row[index] : .null
                return escapeMarkdown(text(of: value))
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        return ([header, separator] + body).joined(separator: "\n")
    }

    static func escapeMarkdown(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    // MARK: SQL INSERT

    static func sqlInsert(
        rows: [[SQLValue]],
        columns: [ColumnInfo],
        database: String?,
        table: String?
    ) -> String {
        guard let table, !table.isEmpty else { return "" }
        let qualifiedTable = SQLIdentifier.qualified(database: database, table: table)
        let columnList = SQLIdentifier.quoteList(columns.map(\.name))
        let statements = rows.map { row -> String in
            let values = columns.enumerated().map { index, column -> String in
                let value = index < row.count ? row[index] : .null
                return SQLValueLiteral.literal(for: value, column: column)
            }.joined(separator: ", ")
            return "INSERT INTO \(qualifiedTable) (\(columnList)) VALUES (\(values));"
        }
        return statements.joined(separator: "\n")
    }

    // MARK: 辅助

    static func newline(_ options: CopyOptions) -> String {
        options.lineEnding == .crlf ? "\r\n" : "\n"
    }

    static func csvWriteOptions(_ options: CopyOptions, includeHeader: Bool) -> CSVWriteOptions {
        CSVWriteOptions(
            delimiter: options.csvDelimiter,
            lineEnding: options.lineEnding,
            includeHeader: includeHeader,
            encoding: .utf8,
            nullRepresentation: options.nullRepresentation
        )
    }
}
