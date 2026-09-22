import Foundation

/// 把映射后的 CSV 行生成分批 `INSERT`，以及从 CSV 推断结果生成 `CREATE TABLE`。
///
/// 技术设计见 `docs/tech-designs/11-schema-and-import-export.md` §4：
/// 批量 `INSERT … VALUES (…), (…)`，每批 500 行；值走与手工编辑相同的字面量路径。
/// 纯函数，便于单测。
public enum CSVImportStatementBuilder {

    // MARK: INSERT

    /// 生成分批 INSERT。`columns` 与 `rows[i].fields` 一一对应。
    public static func insertBatches(
        database: String,
        table: String,
        columns: [ColumnInfo],
        rows: [ImportRow],
        options: ImportOptions,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) -> [ImportInsertBatch] {
        guard !rows.isEmpty, !columns.isEmpty else { return [] }
        let batchSize = max(1, options.batchSize)
        var batches: [ImportInsertBatch] = []
        var index = 0
        while index < rows.count {
            let end = min(index + batchSize, rows.count)
            let slice = Array(rows[index..<end])
            let sql = insertStatement(
                database: database,
                table: table,
                columns: columns,
                rows: slice,
                options: options,
                escaper: escaper
            )
            batches.append(ImportInsertBatch(sql: sql, rows: slice))
            index = end
        }
        return batches
    }

    /// 单批 `INSERT`（也可用于失败后的逐行重试）。
    public static func insertStatement(
        database: String,
        table: String,
        columns: [ColumnInfo],
        rows: [ImportRow],
        options: ImportOptions,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) -> String {
        let qualified = SQLIdentifier.qualified(database: database, table: table)
        let columnList = SQLIdentifier.quoteList(columns.map(\.name))
        let values = rows.map { row in
            valueTuple(row: row, columns: columns, options: options, escaper: escaper)
        }
        return "INSERT INTO \(qualified) (\(columnList)) VALUES \(values.joined(separator: ", "))"
    }

    static func valueTuple(
        row: ImportRow,
        columns: [ColumnInfo],
        options: ImportOptions,
        escaper: SQLValueLiteral.StringEscaper?
    ) -> String {
        let literals = columns.enumerated().map { index, column -> String in
            guard index < row.fields.count else { return "NULL" }
            let value = ImportValueConversion.value(
                from: row.fields[index],
                column: column,
                emptyIsNull: options.emptyFieldIsNull
            )
            if let escaper {
                return SQLValueLiteral.literal(
                    for: value,
                    column: column,
                    escaper: escaper,
                    introducer: options.introducer
                )
            }
            return SQLValueLiteral.literal(
                for: value,
                column: column,
                escaping: options.escaping,
                introducer: options.introducer
            )
        }
        return "(\(literals.joined(separator: ", ")))"
    }

    // MARK: CREATE TABLE

    /// 由推断结果生成建表语句，执行前展示给用户确认。
    public static func createTableStatement(
        database: String,
        tableName: String,
        columns: [CSVColumnInference]
    ) -> String {
        let qualified = SQLIdentifier.qualified(database: database, table: tableName)
        let resolved = columns.isEmpty
            ? [CSVColumnInference(name: "col_1", type: .text, reason: "空文件")]
            : columns
        let definitions = resolved.map { column in
            "  \(SQLIdentifier.quote(column.name)) \(column.type.sqlText)"
        }
        return "CREATE TABLE \(qualified) (\n\(definitions.joined(separator: ",\n"))\n);"
    }
}

// MARK: - 失败行报告

/// 失败行导出成 CSV（`specs/08-import-export.md` §2「有失败行」）。
public enum ImportFailureReport {

    public static let csvHeader = ["行号", "错误", "原始内容"]

    /// 生成失败行 CSV 文本，最多前 100 条（由调用方截断）。
    public static func csv(
        failures: [ImportFailure],
        delimiter: UInt8 = CSVCodec.comma
    ) -> String {
        let options = CSVWriteOptions(
            delimiter: delimiter,
            lineEnding: .lf,
            includeHeader: true,
            encoding: .utf8,
            nullRepresentation: .emptyString
        )
        let rows: [[CSVField]] = failures.map { failure in
            [
                .text(String(failure.lineNumber)),
                .text(failure.message),
                .text(failure.fields.joined(separator: String(UnicodeScalar(delimiter)))),
            ]
        }
        return CSVCodec.encodeString(header: csvHeader, rows: rows, options: options)
    }
}
