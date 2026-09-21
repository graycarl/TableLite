import Foundation

// MARK: - CSV 导入
//
// 流程：流式读文件 → 预览 → 列映射 → 生成 INSERT。见 docs/tech-designs/11-schema-and-import-export.md §4、
// specs/08-import-export.md §2。值走与手工编辑相同的 `SQLValueLiteral` 路径。
enum CSVImporter {

    /// CSV 源列 → 目标列映射；`targetColumn == nil` 表示跳过。
    struct ColumnMapping: Hashable, Sendable {
        var sourceIndex: Int
        var targetColumn: String?
    }

    /// 推断出的列名与类型。`inferredType` 例如 `varchar(255)` / `int` / `bigint` /
    /// `decimal(20,6)` / `datetime` / `text`。
    struct TypeInference: Hashable, Sendable {
        var columnName: String
        var inferredType: String
    }

    struct Failure: Hashable, Sendable {
        var rowNumber: Int
        var content: [String]
        var message: String
    }

    // MARK: - 列推断（从 CSV 新建表，specs/08 §2）

    /// 扫前若干行推断列名与类型；列名重复或为空 → `col_N`（N 为 1-based 列号）。
    ///
    /// - `hasHeader == true` 时首行作为列名，不参与类型推断。
    static func inferColumns(rows: [[String]], hasHeader: Bool, sampleLimit: Int) -> [TypeInference] {
        guard !rows.isEmpty else { return [] }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return [] }

        let header = hasHeader ? rows[0] : []
        let dataRows = Array(rows.dropFirst(hasHeader ? 1 : 0).prefix(max(0, sampleLimit)))

        var result: [TypeInference] = []
        var usedNames = Set<String>()
        for index in 0..<columnCount {
            var name: String
            if hasHeader, index < header.count,
               !header[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = header[index].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = "col_\(index + 1)"
            }
            // 重复时改用 col_N（N 为列号）；若 col_N 也被占用则继续加号保证唯一。
            if usedNames.contains(name) {
                var suffix = index + 1
                while usedNames.contains("col_\(suffix)") { suffix += 1 }
                name = "col_\(suffix)"
            }
            usedNames.insert(name)

            let values = dataRows.map { index < $0.count ? $0[index] : "" }
            result.append(TypeInference(columnName: name, inferredType: inferType(values)))
        }
        return result
    }

    /// 生成 `CREATE TABLE`；表名 / 列名走 `SQLIdentifier`，类型来自推断（受信任的固定集合）。
    static func createTableSQL(table: String,
                               database: String,
                               columns: [TypeInference],
                               fallbackToText: Bool) -> String {
        let qualified = database.isEmpty
            ? SQLIdentifier.quote(table)
            : SQLIdentifier.qualified(database, table)
        let lines = columns.map { column -> String in
            let type = fallbackToText ? "text" : column.inferredType
            return "  \(SQLIdentifier.quote(column.columnName)) \(type)"
        }
        return "CREATE TABLE \(qualified) (\n\(lines.joined(separator: ",\n"))\n) DEFAULT CHARSET=utf8mb4;"
    }

    // MARK: - 批量 INSERT

    /// 每批 `batchSize` 行（默认 500）的批量 INSERT；值走 `SQLValueLiteral`（类型来自目标列）。
    ///
    /// 空字段按 `NULL` 处理（文档未规定导入端 NULL 约定，这里取保守简化，见交付说明）。
    static func insertBatches(table: TableRef,
                              targetColumns: [TableColumn],
                              mapping: [ColumnMapping],
                              rows: [[String]],
                              literalizer: SQLValueLiteralizer,
                              batchSize: Int) -> [String] {
        let active = mapping.filter { $0.targetColumn != nil }
        guard !active.isEmpty, !rows.isEmpty, batchSize > 0 else { return [] }

        var kindByName: [String: ColumnKind] = [:]
        for column in targetColumns { kindByName[column.name] = column.kind }

        let columnList = active.compactMap(\.targetColumn)
        let prefix = "INSERT INTO \(SQLIdentifier.qualified(table.database, table.table)) "
            + "(\(SQLIdentifier.list(columnList))) VALUES "

        var statements: [String] = []
        var start = 0
        while start < rows.count {
            let end = min(start + batchSize, rows.count)
            let tuples = (start..<end).map { rowIndex -> String in
                let row = rows[rowIndex]
                let values = active.map { map -> String in
                    let text = map.sourceIndex < row.count ? row[map.sourceIndex] : ""
                    let value: CellValue = text.isEmpty ? .null : .text(text)
                    let kind = map.targetColumn.flatMap { kindByName[$0] } ?? .text
                    return SQLValueLiteral.literal(value, kind: kind, using: literalizer)
                }
                return "(" + values.joined(separator: ", ") + ")"
            }
            statements.append(prefix + tuples.joined(separator: ", "))
            start = end
        }
        return statements
    }

    // MARK: - 类型校验

    /// 逐行类型校验（数字 / 日期），返回前 100 条失败。
    ///
    /// `rowNumber` 为传入 `rows` 的 1-based 序号；调用方需要表头偏移时自行加上。
    static func validate(rows: [[String]],
                         mapping: [ColumnMapping],
                         targetColumns: [TableColumn]) -> [Failure] {
        var columnsByName: [String: TableColumn] = [:]
        for column in targetColumns { columnsByName[column.name] = column }

        let active = mapping.compactMap { map -> (sourceIndex: Int, column: TableColumn)? in
            guard let name = map.targetColumn, let column = columnsByName[name] else { return nil }
            return (map.sourceIndex, column)
        }
        guard !active.isEmpty else { return [] }

        var failures: [Failure] = []
        for (rowIndex, row) in rows.enumerated() {
            var message: String?
            for entry in active {
                let text = entry.sourceIndex < row.count ? row[entry.sourceIndex] : ""
                if text.isEmpty {
                    if !entry.column.isNullable {
                        message = "列 \(entry.column.name) 不允许为空"
                        break
                    }
                    continue
                }
                if let reason = typeError(text, column: entry.column) {
                    message = "列 \(entry.column.name) \(reason)"
                    break
                }
            }
            if let message {
                failures.append(Failure(rowNumber: rowIndex + 1, content: row, message: message))
                if failures.count >= 100 { break }
            }
        }
        return failures
    }

    // MARK: - 内部：类型判定

    /// 推断单列类型：整数（int / bigint）→ 小数 → 日期时间 → 文本。
    static func inferType(_ values: [String]) -> String {
        let nonEmpty = values.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "varchar(255)" }

        var maxLength = 0
        var allInteger = true
        var allNumeric = true
        var allDateTime = true
        var needsBigInt = false
        for value in nonEmpty {
            maxLength = max(maxLength, value.count)
            let integer = isInteger(value)
            if allInteger, !integer { allInteger = false }
            if allNumeric, !(integer || isDecimal(value)) { allNumeric = false }
            if allDateTime, !isDateTime(value) { allDateTime = false }
            if integer, !fitsInInt32(value) { needsBigInt = true }
        }

        if allInteger { return needsBigInt ? "bigint" : "int" }
        if allNumeric { return "decimal(20,6)" }
        if allDateTime { return "datetime" }
        return maxLength > 255 ? "text" : "varchar(255)"
    }

    private static func typeError(_ text: String, column: TableColumn) -> String? {
        switch column.kind {
        case .integer:
            return isInteger(text) ? nil : "不是合法整数"
        case .decimal, .floating:
            return (isInteger(text) || isDecimal(text)) ? nil : "不是合法数字"
        case .date, .dateTime, .timestamp:
            return isDateTime(text) ? nil : "不是合法日期时间"
        case .time:
            return isTime(text[...]) ? nil : "不是合法时间"
        case .year:
            return (text.count == 4 && isInteger(text)) ? nil : "不是合法年份"
        default:
            return nil
        }
    }

    /// `^-?\d+$`
    private static func isInteger(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return false }
        var index = 0
        if bytes[0] == 0x2D { index += 1 } // '-'
        guard index < bytes.count else { return false }
        while index < bytes.count {
            guard bytes[index] >= 0x30, bytes[index] <= 0x39 else { return false }
            index += 1
        }
        return true
    }

    /// `^-?\d+\.\d+$`
    private static func isDecimal(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return false }
        var index = 0
        if bytes[0] == 0x2D { index += 1 }
        var integerDigits = 0
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            index += 1; integerDigits += 1
        }
        guard integerDigits > 0, index < bytes.count, bytes[index] == 0x2E else { return false }
        index += 1
        var fractionDigits = 0
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            index += 1; fractionDigits += 1
        }
        return fractionDigits > 0 && index == bytes.count
    }

    private static func fitsInInt32(_ text: String) -> Bool {
        guard let value = Int(text) else { return false }
        return value >= Int(Int32.min) && value <= Int(Int32.max)
    }

    /// 支持 `YYYY-MM-DD`、`YYYY-MM-DD HH:MM`、`YYYY-MM-DD HH:MM:SS`、`T` 分隔。
    private static func isDateTime(_ text: String) -> Bool {
        var datePart = text[...]
        var timePart: Substring?
        if let separator = text.firstIndex(where: { $0 == " " || $0 == "T" }) {
            datePart = text[text.startIndex..<separator]
            timePart = text[text.index(after: separator)...]
        }
        guard isDate(datePart) else { return false }
        if let timePart { return isTime(timePart) }
        return true
    }

    private static func isDate(_ text: Substring) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return false
        }
        return year >= 1000 && (1...12).contains(month) && (1...31).contains(day)
    }

    private static func isTime(_ text: Substring) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return false
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return false }
        if parts.count == 3 {
            guard let second = Int(parts[2]), (0...59).contains(second) else { return false }
        }
        return true
    }
}
