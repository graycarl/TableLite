import Foundation
import Observation

/// 从 CSV 新建表时，由推断类型构造列元数据（字面量生成需要 `ColumnInfo`）。
public enum ImportNewTableColumnFactory {

    public static func columnInfo(name: String, type: CSVColumnType) -> ColumnInfo {
        switch type {
        case .int:
            return ColumnInfo(name: name, fieldType: .long, charsetNumber: 0, dataType: "int", columnTypeText: "int")
        case .bigint:
            return ColumnInfo(name: name, fieldType: .longlong, charsetNumber: 0, dataType: "bigint", columnTypeText: "bigint")
        case .decimal:
            return ColumnInfo(name: name, fieldType: .newdecimal, charsetNumber: 0, dataType: "decimal", columnTypeText: "decimal(10,2)")
        case .dateTime:
            return ColumnInfo(name: name, fieldType: .datetime, charsetNumber: 0, dataType: "datetime", columnTypeText: "datetime")
        case .varchar:
            return ColumnInfo(name: name, fieldType: .varString, charsetNumber: 33, dataType: "varchar", columnTypeText: "varchar(255)")
        case .text:
            return ColumnInfo(name: name, fieldType: .blob, charsetNumber: 33, dataType: "text", columnTypeText: "text")
        }
    }
}

/// CSV 导入向导的状态机与执行逻辑。
///
/// 需求见 `specs/08-import-export.md` §2；只读拦截见 `specs/09-readonly-mode.md` §4；
/// 分批 INSERT / 事务策略见 `docs/tech-designs/11-schema-and-import-export.md` §4。
@MainActor
@Observable
public final class ImportViewModel {

    public enum Step: Sendable, Equatable {
        case pickFile
        case mapping
        case executing
    }

    /// 第一分隔符下拉的取值。
    public enum DelimiterOption: String, Sendable, CaseIterable, Equatable, Hashable {
        case auto
        case comma
        case tab
        case semicolon
        case pipe

        public var byte: UInt8? {
            switch self {
            case .auto: return nil
            case .comma: return CSVCodec.comma
            case .tab: return CSVCodec.tab
            case .semicolon: return CSVCodec.semicolon
            case .pipe: return CSVCodec.pipe
            }
        }

        public var displayName: String {
            switch self {
            case .auto: return "自动检测"
            case .comma: return "逗号（,）"
            case .tab: return "制表符（Tab）"
            case .semicolon: return "分号（;）"
            case .pipe: return "竖线（|）"
            }
        }
    }

    // MARK: 依赖

    public let session: ConnectionSession
    public var isReadOnly: Bool { session.isReadOnly }
    public var onFinish: ((ImportSummary) -> Void)?

    // MARK: 步骤

    public private(set) var step: Step = .pickFile

    // MARK: 第一步

    public private(set) var fileURL: URL?
    public var delimiterOption: DelimiterOption = .auto
    public var hasHeader: Bool = true
    public var encodingOption: CSVInputEncoding = .auto
    public private(set) var parsedResult: CSVParseResult?
    public private(set) var parseError: String?
    public private(set) var isLoading = false
    /// 预览行数上限。
    public let previewRowLimit = 20

    // MARK: 第二步

    /// 入口若带了默认表，这里保留一份，用于在「已有表 / 新表」之间切换。
    public let defaultExistingTable: String?

    /// 目标模式开关（第二步的 Picker 绑定）。
    public var isNewTableTarget: Bool {
        get {
            if case .newTable = target { return true }
            return false
        }
        set {
            if newValue {
                target = .newTable(database: target.database, tableName: newTableName)
            } else if let table = defaultExistingTable {
                target = .existingTable(database: target.database, table: table)
            }
        }
    }

    public private(set) var targetColumns: [ColumnInfo] = []
    public var target: ImportTarget
    public var mappings: [ImportColumnMapping] = []
    public var newTableName: String = ""
    /// 导入前是否把整表类型改成文本。
    public var useTextForAllColumns = false

    // MARK: 选项

    public var options = ImportOptions()

    // MARK: 第三步

    public private(set) var phase: ImportPhase = .idle
    public private(set) var rowsWritten = 0
    public private(set) var failureCount = 0
    public private(set) var failures: [ImportFailure] = []
    public private(set) var createdTableSQL: String?

    @ObservationIgnored private var executionTask: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false

    // MARK: 初始化

    public init(session: ConnectionSession, defaultDatabase: String?, defaultTable: String?) {
        self.session = session
        let database = defaultDatabase ?? session.selectedDatabase ?? session.connection.mysql.database
        self.defaultExistingTable = defaultTable
        if let defaultTable, !defaultTable.isEmpty {
            self.target = .existingTable(database: database, table: defaultTable)
            self.newTableName = defaultTable + "_imported"
        } else {
            self.target = .newTable(database: database, tableName: "")
        }
    }

    // MARK: - 第一步：选文件与解析

    public func chooseFile() {
        guard !isReadOnly else { return }
        if let url = ImportExportFilePanels.chooseCSVFile() {
            load(url: url)
        }
    }

    public func load(url: URL) {
        fileURL = url
        if newTableName.isEmpty {
            newTableName = Self.suggestedTableName(from: url)
        }
        reparse()
    }

    /// 分隔符 / 编码 / 表头变化后重新解析。
    public func reparse() {
        guard fileURL != nil else { return }
        isLoading = true
        parseError = nil
        Task { [weak self] in
            await self?.performParse()
            self?.isLoading = false
        }
    }

    private func performParse() async {
        guard let url = fileURL else { return }
        let options = CSVParseOptions(
            delimiter: delimiterOption.byte,
            hasHeader: hasHeader,
            encoding: encodingOption
        )
        do {
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            let result = try await Task.detached { try CSVCodec.parse(data: data, options: options) }.value
            parsedResult = result
            parseError = nil
        } catch let error as CSVParseError {
            parsedResult = nil
            parseError = error.message
        } catch {
            parsedResult = nil
            parseError = "读取文件失败：\(error)"
        }
    }

    /// CSV 列名（无表头时用 `col_N`）。
    public var csvColumns: [String] {
        guard let parsedResult else { return [] }
        let count = parsedResult.header?.count ?? parsedResult.records.first?.fields.count ?? 0
        return CSVTypeInference.columnNames(header: parsedResult.header, columnCount: count)
    }

    /// 预览用：表头 + 前 N 行。
    public var previewHeader: [String] {
        csvColumns
    }

    public var previewRecords: [CSVRecord] {
        Array(parsedResult?.records.prefix(previewRowLimit) ?? [])
    }

    /// 解析状态提示：自动识别到分隔符 / 编码。
    public var parseHint: String? {
        guard let parsedResult else { return nil }
        let delimiterName: String
        switch parsedResult.delimiter {
        case CSVCodec.comma: delimiterName = "逗号（,）"
        case CSVCodec.tab: delimiterName = "制表符（Tab）"
        case CSVCodec.semicolon: delimiterName = "分号（;）"
        case CSVCodec.pipe: delimiterName = "竖线（|）"
        default: delimiterName = String(UnicodeScalar(parsedResult.delimiter))
        }
        let detected = parsedResult.delimiterWasDetected ? "自动识别到分隔符" : "分隔符无法确定，已回退到"
        return "\(detected)：\(delimiterName) · 编码：\(parsedResult.encoding.displayName)"
    }

    public func canProceedFromPicker() -> Bool {
        parsedResult != nil && !isLoading
    }

    /// 第一步 → 第二步。
    public func goToMapping() async {
        await prepareMapping()
    }

    /// 第二步 → 第一步。
    public func goBackToFilePicker() {
        step = .pickFile
    }

    // MARK: - 第二步：列映射

    /// 进入第二步：读取目标表结构并自动匹配（新表模式改为类型推断）。
    public func prepareMapping() async {
        guard parsedResult != nil, !isReadOnly else { return }
        let columns = csvColumns
        switch target {
        case .existingTable(let database, let table):
            do {
                let structure = try await session.meta.structure(database: database, table: table)
                targetColumns = structure.columns
                mappings = ImportColumnMapper.autoMap(csvColumns: columns, targetColumns: structure.columns)
            } catch {
                parseError = "读取目标表结构失败：\(error)"
                return
            }
        case .newTable:
            targetColumns = []
            let inferences = CSVTypeInference.infer(
                header: parsedResult?.header,
                rows: parsedResult?.records.map(\.fields) ?? []
            )
            mappings = inferences.enumerated().map { index, inference in
                ImportColumnMapping(
                    csvIndex: index,
                    csvName: inference.name,
                    targetColumn: inference.name,
                    deducedType: inference.type,
                    note: inference.reason
                )
            }
            if newTableName.isEmpty, let url = fileURL {
                newTableName = Self.suggestedTableName(from: url)
            }
            if useTextForAllColumns {
                applyTextForAllColumns()
            }
        }
        step = .mapping
    }

    /// 「全部按文本类型创建」快捷操作。
    public func applyTextForAllColumns() {
        for index in mappings.indices {
            mappings[index].deducedType = .varchar
            mappings[index].note = "按文本"
        }
    }

    /// 未映射但不可空的列。
    public var requiredColumnWarnings: [ColumnInfo] {
        ImportColumnMapper.unmappedRequiredColumns(mappings: mappings, targetColumns: targetColumns)
    }

    /// 待导入行数。
    public var plannedRowCount: Int {
        parsedResult?.records.count ?? 0
    }

    /// 新表模式下的建表语句预览。
    public var previewCreateTableSQL: String? {
        guard case .newTable(let database, _) = target else { return nil }
        let inferences = mappings.map {
            CSVColumnInference(name: $0.targetColumn ?? $0.csvName, type: $0.deducedType, reason: $0.note)
        }
        return CSVImportStatementBuilder.createTableStatement(
            database: database,
            tableName: newTableName,
            columns: inferences
        )
    }

    public var canProceedToExecute: Bool {
        guard !isReadOnly, mappings.contains(where: { !$0.isSkipped }) else { return false }
        if case .newTable = target {
            return !newTableName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    // MARK: - 第三步：执行

    public func startImport() {
        guard !isReadOnly, phase.isRunning == false else { return }
        step = .executing
        phase = .running
        cancelled = false
        rowsWritten = 0
        failureCount = 0
        failures = []
        createdTableSQL = nil
        executionTask = Task { [weak self] in
            await self?.runImport()
        }
    }

    public func cancel() {
        cancelled = true
        Task { await session.cancelCurrentQuery() }
    }

    public var progressText: String {
        "已写入 \(rowsWritten) 行 / \(plannedRowCount)"
    }

    /// 失败行 CSV 文本（最多 100 条）。
    public func failureReportCSV() -> String {
        ImportFailureReport.csv(failures: Array(failures.prefix(100)))
    }

    private func runImport() async {
        guard let parsed = parsedResult else { return }

        let mapped = mappings.enumerated().filter { $0.element.targetColumn != nil }
        let insertColumns: [ColumnInfo]
        switch target {
        case .existingTable:
            insertColumns = mapped.compactMap { pair in
                targetColumns.first { $0.name == pair.element.targetColumn }
            }
        case .newTable:
            insertColumns = mapped.map { pair in
                ImportNewTableColumnFactory.columnInfo(
                    name: pair.element.targetColumn ?? pair.element.csvName,
                    type: pair.element.deducedType
                )
            }
        }

        var runOptions = options
        runOptions.batchSize = max(1, options.batchSize)
        runOptions.introducer = session.mysql.charsetIntroducer
        let escaper = session.mysql.makeEscaper()

        // 行数据按已映射列裁剪。
        let insertRows: [ImportRow] = parsed.records.map { record in
            let fields = mapped.map { pair -> String in
                pair.offset < record.fields.count ? record.fields[pair.offset] : ""
            }
            return ImportRow(fields: fields, lineNumber: record.lineNumber)
        }

        var createdSQL: String?
        do {
            if case .newTable(let database, let tableName) = target {
                let inferences = mapped.map { pair in
                    CSVColumnInference(
                        name: pair.element.targetColumn ?? pair.element.csvName,
                        type: pair.element.deducedType,
                        reason: pair.element.note
                    )
                }
                let sql = CSVImportStatementBuilder.createTableStatement(
                    database: database,
                    tableName: tableName,
                    columns: inferences
                )
                createdSQL = sql
                try await runStatement(sql)
            }

            if options.truncateFirst {
                let qualified = SQLIdentifier.qualified(database: target.database, table: target.tableName)
                try await runStatement("TRUNCATE TABLE \(qualified)")
            }

            let batches = CSVImportStatementBuilder.insertBatches(
                database: target.database,
                table: target.tableName,
                columns: insertColumns,
                rows: insertRows,
                options: runOptions,
                escaper: escaper
            )

            if options.useTransaction, !runOptions.continueOnError {
                try await runTransactional(batches: batches)
            } else {
                await runPerBatch(
                    batches: batches,
                    insertColumns: insertColumns,
                    options: runOptions,
                    escaper: escaper
                )
            }
        } catch {
            recordFailure(lineNumber: 0, fields: [], message: Self.message(error))
        }

        createdTableSQL = createdSQL
        let wasCancelled = cancelled
        let summary = ImportSummary(
            successCount: rowsWritten,
            failureCount: failureCount,
            wasCancelled: wasCancelled,
            createdTableSQL: createdSQL,
            message: Self.summaryMessage(
                success: rowsWritten,
                failure: failureCount,
                cancelled: wasCancelled
            )
        )
        phase = .done(summary)
        onFinish?(summary)
    }

    /// 事务模式：要么全部成功，要么全部回滚。
    private func runTransactional(batches: [ImportInsertBatch]) async throws {
        try await runStatement("START TRANSACTION")
        var failed = false
        for batch in batches {
            if cancelled { failed = true; break }
            do {
                try await runStatement(batch.sql)
                rowsWritten += batch.rows.count
            } catch {
                recordFailure(
                    lineNumber: batch.firstLineNumber,
                    fields: batch.rows.first?.fields ?? [],
                    message: Self.message(error)
                )
                failed = true
                break
            }
        }
        if failed || cancelled {
            try? await runStatement("ROLLBACK")
            rowsWritten = 0
        } else {
            try await runStatement("COMMIT")
        }
    }

    /// 非事务模式：逐批提交；批失败时逐行定位并把失败行记入报告（部分成功）。
    private func runPerBatch(
        batches: [ImportInsertBatch],
        insertColumns: [ColumnInfo],
        options: ImportOptions,
        escaper: SQLValueLiteral.StringEscaper?
    ) async {
        for batch in batches {
            if cancelled { break }
            do {
                try await runStatement(batch.sql)
                rowsWritten += batch.rows.count
            } catch {
                for row in batch.rows {
                    if cancelled { break }
                    do {
                        let sql = CSVImportStatementBuilder.insertStatement(
                            database: target.database,
                            table: target.tableName,
                            columns: insertColumns,
                            rows: [row],
                            options: options,
                            escaper: escaper
                        )
                        try await runStatement(sql)
                        rowsWritten += 1
                    } catch {
                        recordFailure(
                            lineNumber: row.lineNumber,
                            fields: row.fields,
                            message: Self.message(error)
                        )
                        if !options.continueOnError { break }
                    }
                }
                if !options.continueOnError { break }
            }
        }
    }

    /// 执行一条导入语句。
    ///
    /// **关键**：`ConnectionSession.execute` 对语句级错误不抛异常，而是放在
    /// `result.firstError` 里（`03-mysql-layer.md` §3），必须显式检查。
    /// 导入的成批 INSERT 不写查询历史，避免把历史刷爆。
    private func runStatement(_ sql: String) async throws {
        let result = try await session.execute(sql, database: target.database, recordHistory: false)
        if let error = result.firstError {
            throw error
        }
    }

    private func recordFailure(lineNumber: Int, fields: [String], message: String) {
        failureCount += 1
        guard failures.count < 100 else { return }
        failures.append(ImportFailure(lineNumber: lineNumber, fields: fields, message: message))
    }

    // MARK: - 辅助

    static func suggestedTableName(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let sanitized = base.isEmpty ? "imported" : base
        return "\(sanitized)_imported"
    }

    private static func summaryMessage(success: Int, failure: Int, cancelled: Bool) -> String {
        if cancelled {
            return "导入已取消：成功 \(success) 行，失败 \(failure) 行"
        }
        if failure > 0 {
            return "导入结束：成功 \(success) 行，失败 \(failure) 行"
        }
        return "导入完成：成功 \(success) 行"
    }

    static func message(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return "[错误 \(mysqlError.code)] \(mysqlError.message)"
        }
        return String(describing: error)
    }
}
