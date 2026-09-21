import AppKit
import Combine
import Foundation
import os
import UniformTypeIdentifiers

// MARK: - 导入 ViewModel
//
// 三步向导：选文件 → 列映射 → 执行。见 specs/08-import-export.md §2、
// docs/tech-designs/11-schema-and-import-export.md §4。
//
// 线程：整个类型 `@MainActor`；数据库访问 `await` 到 `MySQLSession`。
// 值一律走 `CSVImporter` / `SQLValueLiteral`，不手工拼引号。
@MainActor
final class ImportViewModel: ObservableObject {

    // MARK: 步骤

    enum Step: Int, CaseIterable, Identifiable {
        case selectFile = 1
        case mapping = 2
        case execute = 3

        var id: Int { rawValue }
        var title: String { "导入 CSV（\(rawValue)/3）" }
    }

    enum TargetMode: String, CaseIterable, Identifiable {
        case existingTable
        case newTable

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .existingTable: return "已有表"
            case .newTable: return "导入到新表"
            }
        }
    }

    /// 手动选择的编码（自动检测失败时用）。会把文件转成 UTF-8 后再解析。
    enum ManualEncoding: String, CaseIterable, Identifiable {
        case utf8 = "UTF-8"
        case gb18030 = "GB18030"
        case utf16 = "UTF-16"

        var id: String { rawValue }
        var displayName: String { rawValue }

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .gb18030: return Self.gb18030Encoding
            case .utf16: return .utf16
            }
        }

        private static let gb18030Encoding: String.Encoding = {
            let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }()
    }

    struct MappingRow: Identifiable, Hashable {
        /// 源列下标
        var id: Int
        var sourceName: String
        /// nil 表示跳过
        var targetColumn: String?
    }

    struct NewColumn: Identifiable, Hashable {
        var id: Int
        var name: String
        var type: String
    }

    // MARK: 依赖

    private let session: ConnectionSession
    private let preferences: PreferencesStore
    private let fileSystem: FileSystemLocator
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    /// 每批 INSERT 的行数（docs/11 §4）。
    private let batchSize = 500
    /// 预览前 N 行（specs/08 §2）。
    private let previewLimit = 20
    /// 类型推断采样行数。
    private let inferenceSampleLimit = 100

    // MARK: 状态：通用

    @Published private(set) var step: Step = .selectFile

    // MARK: 状态：第一步

    @Published private(set) var fileURL: URL?
    @Published private(set) var previewRows: [[String]] = []
    @Published private(set) var detectedEncodingName: String?
    @Published var hasHeader = true
    @Published var delimiter: CSVDelimiter = .comma
    @Published var manualEncoding: ManualEncoding = .utf8
    @Published private(set) var needsManualEncoding = false
    @Published private(set) var parseErrorMessage: String?
    @Published private(set) var delimiterHint: String?

    // MARK: 状态：第二步

    @Published var targetMode: TargetMode = .existingTable
    @Published var targetRef: TableRef?
    @Published private(set) var targetStructure: TableStructure?
    @Published private(set) var mappings: [MappingRow] = []
    @Published var continueOnError = false
    @Published var truncateBeforeImport = false
    @Published var useTransaction = true
    @Published var newTableName = ""
    @Published private(set) var newColumns: [NewColumn] = []
    @Published var fallbackAllText = false
    @Published private(set) var isLoadingTarget = false

    // MARK: 状态：第三步

    @Published private(set) var isImporting = false
    @Published private(set) var finished = false
    @Published private(set) var processedRows = 0
    @Published private(set) var successCount = 0
    @Published private(set) var failureCount = 0
    @Published private(set) var failures: [CSVImporter.Failure] = []
    @Published private(set) var cancellationNotice: String?
    @Published private(set) var errorMessage: String?

    // MARK: 私有

    private var rawRows: [[String]] = []
    private var fileData: Data?
    private var importTask: Task<Void, Never>?
    private var cancellationToken: CancellationToken?

    // MARK: 初始化

    init(session: ConnectionSession,
         preferences: PreferencesStore,
         fileSystem: FileSystemLocator) {
        self.session = session
        self.preferences = preferences
        self.fileSystem = fileSystem
        self.delimiter = preferences.csvDelimiter
    }

    // MARK: 派生

    var database: String { session.selectedDatabase ?? "" }

    var dataRows: [[String]] {
        hasHeader ? Array(rawRows.dropFirst()) : rawRows
    }

    var sourceColumnCount: Int { rawRows.first?.count ?? 0 }

    var sourceColumnNames: [String] {
        let header = hasHeader ? (rawRows.first ?? []) : []
        return (0..<sourceColumnCount).map { index in
            let name = index < header.count
                ? header[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            return name.isEmpty ? "col_\(index + 1)" : name
        }
    }

    var sourceRows: [[String]] { dataRows }

    var estimatedRowCount: Int { dataRows.count }

    var targetTables: [DatabaseObject] {
        session.objects.filter { $0.kind == .table }
    }

    var canAdvance: Bool {
        switch step {
        case .selectFile:
            return fileURL != nil
                && parseErrorMessage == nil
                && !needsManualEncoding
                && !rawRows.isEmpty
        case .mapping:
            guard mappings.contains(where: { $0.targetColumn != nil }) else { return false }
            switch targetMode {
            case .existingTable:
                return targetRef != nil && targetStructure != nil
            case .newTable:
                return !newTableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !newColumns.isEmpty
            }
        case .execute:
            return false
        }
    }

    /// 已有表模式下，目标列不可为空但没有映射的列（导入前警告）。
    var unmappedRequiredColumns: [String] {
        guard targetMode == .existingTable, let structure = targetStructure else { return [] }
        let mapped = Set(mappings.compactMap(\.targetColumn))
        return structure.columns
            .filter { column in
                !column.isNullable
                    && !column.isGenerated
                    && !column.isAutoIncrement
                    && column.defaultValue == nil
                    && !mapped.contains(column.name)
            }
            .map(\.name)
    }

    /// 新表模式下可选的常见类型（specs/08 §2）。
    static let newColumnTypes = [
        "text", "varchar(255)", "int", "bigint", "decimal(20,6)", "datetime", "date", "double"
    ]

    var createTableSQL: String {
        CSVImporter.createTableSQL(
            table: newTableName.trimmingCharacters(in: .whitespacesAndNewlines),
            database: database,
            columns: newColumns.map {
                CSVImporter.TypeInference(columnName: $0.name, inferredType: $0.type)
            },
            fallbackToText: fallbackAllText
        )
    }

    // MARK: - 第一步：选文件

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadFile(url)
    }

    func loadFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            fileURL = url
            fileData = data
            newTableName = Self.suggestedTableName(from: url)
            delimiterHint = nil
            parseData(data, delimiter: nil)
        } catch {
            logger.error("读取 CSV 失败：\(String(describing: error), privacy: .public)")
            parseErrorMessage = "读取文件失败：\(error.localizedDescription)"
            rawRows = []
            previewRows = []
        }
    }

    /// 用户改分隔符后重新解析。
    func reparseWithChosenDelimiter() {
        guard let fileData else { return }
        parseData(fileData, delimiter: delimiter.character)
    }

    /// 自动检测失败后用手动编码重新解析。
    func reparseWithManualEncoding() {
        guard let fileData else { return }
        guard let text = String(data: fileData, encoding: manualEncoding.stringEncoding) else {
            parseErrorMessage = "用 \(manualEncoding.displayName) 解码失败，请换一种编码。"
            return
        }
        parseData(Data(text.utf8), delimiter: delimiter.character)
    }

    private func parseData(_ data: Data, delimiter chosen: Character?) {
        do {
            let result = try CSVCodec.parse(data, delimiter: chosen)
            rawRows = result.rows
            previewRows = Array(result.rows.prefix(previewLimit))
            detectedEncodingName = result.detectedEncoding
            needsManualEncoding = false
            parseErrorMessage = nil
            delimiter = CSVDelimiter.allCases.first { $0.character == result.detectedDelimiter } ?? .comma
            let columnCount = result.rows.first?.count ?? 0
            delimiterHint = columnCount <= 1
                ? "未能自动确定分隔符，请确认下面的选择是否正确。"
                : nil
            rebuildMappingsFromCurrentSource()
        } catch let error as CSVCodec.ParseError {
            rawRows = []
            previewRows = []
            detectedEncodingName = nil
            parseErrorMessage = Self.describe(error)
            needsManualEncoding = (error == .undecodableText)
        } catch {
            rawRows = []
            previewRows = []
            parseErrorMessage = "解析失败：\(error.localizedDescription)"
        }
    }

    private static func describe(_ error: CSVCodec.ParseError) -> String {
        switch error {
        case .emptyFile:
            return "文件是空的。"
        case .unclosedQuote(let row):
            return "第 \(row) 行有未闭合的引号。"
        case .inconsistentColumns(let row, let expected, let actual):
            return "第 \(row) 行的列数是 \(actual)，与表头的 \(expected) 列不一致。"
        case .undecodableText:
            return "无法识别文件编码，请手动选择编码。"
        }
    }

    private static func suggestedTableName(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let sanitized = base.map { character -> Character in
            character.isLetter || character.isNumber || character == "_"
                ? character
                : "_"
        }
        let name = String(sanitized)
        return name.isEmpty ? "imported_table" : name
    }

    // MARK: - 步骤推进

    func advance() async {
        switch step {
        case .selectFile:
            guard canAdvance else { return }
            step = .mapping
            await prepareMappingStep()
        case .mapping:
            guard canAdvance else { return }
            step = .execute
        case .execute:
            break
        }
    }

    func goBack() {
        switch step {
        case .mapping: step = .selectFile
        case .execute: step = .mapping
        case .selectFile: break
        }
    }

    // MARK: - 第二步：目标与映射

    func prepareMappingStep() async {
        if targetRef == nil, let first = targetTables.first {
            targetRef = TableRef(database: database, table: first.name)
        }
        switch targetMode {
        case .existingTable:
            await loadTargetStructure()
        case .newTable:
            rebuildNewColumns()
        }
    }

    func selectTargetTable(_ ref: TableRef) async {
        targetRef = ref
        await loadTargetStructure()
    }

    private func loadTargetStructure() async {
        guard let ref = targetRef else {
            targetStructure = nil
            return
        }
        isLoadingTarget = true
        defer { isLoadingTarget = false }
        do {
            let structure = try await session.meta.structure(ref)
            targetStructure = structure
            rebuildMappingsFromCurrentSource()
        } catch {
            logger.error("读取目标表结构失败：\(String(describing: error), privacy: .public)")
            targetStructure = nil
            errorMessage = (error as? MySQLError)?.title ?? "读取目标表结构失败"
        }
    }

    /// 用户改表头判断 / 分隔符 / 目标表后重建列映射。
    func rebuildMappingsFromCurrentSource() {
        let names = sourceColumnNames
        let existing = Dictionary(uniqueKeysWithValues: mappings.map { ($0.id, $0.targetColumn) })
        mappings = names.enumerated().map { index, name in
            let target: String?
            if let previous = existing[index] {
                target = previous
            } else {
                target = Self.matchTargetColumn(name: name, in: targetStructure)
            }
            return MappingRow(id: index, sourceName: name, targetColumn: target)
        }
    }

    private static func matchTargetColumn(name: String, in structure: TableStructure?) -> String? {
        guard let structure, !name.isEmpty else { return nil }
        if let exact = structure.columns.first(where: { $0.name == name }) { return exact.name }
        let lowered = name.lowercased()
        return structure.columns.first { $0.name.lowercased() == lowered }?.name
    }

    func setMapping(sourceIndex: Int, targetColumn: String?) {
        guard let index = mappings.firstIndex(where: { $0.id == sourceIndex }) else { return }
        mappings[index].targetColumn = targetColumn
    }

    func rebuildNewColumns() {
        let inferred = CSVImporter.inferColumns(rows: rawRows,
                                                hasHeader: hasHeader,
                                                sampleLimit: inferenceSampleLimit)
        newColumns = inferred.enumerated().map { index, column in
            NewColumn(id: index, name: column.columnName, type: column.inferredType)
        }
    }

    func setNewColumnName(index: Int, name: String) {
        guard newColumns.indices.contains(index) else { return }
        newColumns[index].name = name
    }

    func setNewColumnType(index: Int, type: String) {
        guard newColumns.indices.contains(index) else { return }
        newColumns[index].type = type
    }

    // MARK: - 第三步：执行

    var progressFraction: Double {
        let total = estimatedRowCount
        guard total > 0 else { return 0 }
        return min(1, Double(processedRows) / Double(total))
    }

    var progressText: String {
        "已写入 \(TableDataViewModelLogic.groupedDigits(processedRows)) 行"
            + " / \(TableDataViewModelLogic.groupedDigits(estimatedRowCount))"
    }

    func startImport() {
        guard !isImporting else { return }
        guard !session.isReadOnly else {
            errorMessage = "该连接处于只读模式，无法导入。"
            return
        }
        resetExecutionState()
        isImporting = true

        let token = CancellationToken()
        cancellationToken = token
        let rows = dataRows
        let headerOffset = hasHeader ? 1 : 0

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runImport(rows: rows, headerOffset: headerOffset, token: token)
            self.isImporting = false
            self.finished = true
            self.importTask = nil
            self.cancellationToken = nil
        }
    }

    func cancel() {
        cancellationToken?.request()
        importTask?.cancel()
        Task { await session.mysql.cancelCurrentQuery() }
    }

    private func resetExecutionState() {
        processedRows = 0
        successCount = 0
        failureCount = 0
        failures = []
        cancellationNotice = nil
        errorMessage = nil
        finished = false
    }

    private func runImport(rows: [[String]], headerOffset: Int, token: CancellationToken) async {
        switch targetMode {
        case .existingTable:
            guard let ref = targetRef, let structure = targetStructure else {
                errorMessage = "请先选择目标表。"
                return
            }
            await importIntoExisting(ref: ref,
                                     structure: structure,
                                     rows: rows,
                                     headerOffset: headerOffset,
                                     token: token)

        case .newTable:
            await importIntoNewTable(rows: rows, headerOffset: headerOffset, token: token)
        }
    }

    private func importIntoExisting(ref: TableRef,
                                    structure: TableStructure,
                                    rows: [[String]],
                                    headerOffset: Int,
                                    token: CancellationToken) async {
        if truncateBeforeImport {
            do {
                try await session.mysql.execute("TRUNCATE TABLE \(SQLIdentifier.qualified(ref.database, ref.table))")
            } catch {
                logger.error("导入前 TRUNCATE 失败：\(String(describing: error), privacy: .public)")
                errorMessage = (error as? MySQLError)?.title ?? "清空目标表失败"
                return
            }
        }
        let mapping = mappings.map {
            CSVImporter.ColumnMapping(sourceIndex: $0.id, targetColumn: $0.targetColumn)
        }
        await insertRows(rows: rows,
                         ref: ref,
                         targetColumns: structure.columns,
                         mapping: mapping,
                         headerOffset: headerOffset,
                         token: token)
    }

    private func importIntoNewTable(rows: [[String]],
                                    headerOffset: Int,
                                    token: CancellationToken) async {
        let name = newTableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !newColumns.isEmpty else {
            errorMessage = "请先填写表名与列。"
            return
        }
        let ref = TableRef(database: database, table: name)
        do {
            try await session.mysql.execute(createTableSQL)
        } catch {
            logger.error("创建目标表失败：\(String(describing: error), privacy: .public)")
            errorMessage = (error as? MySQLError)?.title ?? "创建目标表失败"
            return
        }
        await session.meta.invalidate(ref)

        let targetColumns = newColumns.map { column -> TableColumn in
            let type = fallbackAllText ? "text" : column.type
            let dataType = Self.dataTypeName(of: type)
            return TableColumn(name: column.name,
                               dataType: dataType,
                               rawTypeText: type,
                               kind: ColumnKindClassifier.kind(dataType: dataType, rawTypeText: type))
        }
        let mapping = newColumns.enumerated().map { index, column in
            CSVImporter.ColumnMapping(sourceIndex: index, targetColumn: column.name)
        }
        await insertRows(rows: rows,
                         ref: ref,
                         targetColumns: targetColumns,
                         mapping: mapping,
                         headerOffset: headerOffset,
                         token: token)
    }

    /// 批量 INSERT：事务模式整体成功 / 回滚；非事务模式逐批执行，批失败时拆成单行定位失败行。
    private func insertRows(rows: [[String]],
                            ref: TableRef,
                            targetColumns: [TableColumn],
                            mapping: [CSVImporter.ColumnMapping],
                            headerOffset: Int,
                            token: CancellationToken) async {
        guard !rows.isEmpty else { return }
        let literalizer = await session.mysql.literalizer()
        let batches = CSVImporter.insertBatches(table: ref,
                                                targetColumns: targetColumns,
                                                mapping: mapping,
                                                rows: rows,
                                                literalizer: literalizer,
                                                batchSize: batchSize)
        let singles: [String] = useTransaction ? [] : CSVImporter.insertBatches(
            table: ref,
            targetColumns: targetColumns,
            mapping: mapping,
            rows: rows,
            literalizer: literalizer,
            batchSize: 1
        )

        if useTransaction {
            await runTransactionalImport(batches: batches,
                                         totalRows: rows.count,
                                         token: token)
        } else {
            await runBatchImport(rows: rows,
                                 batches: batches,
                                 singles: singles,
                                 headerOffset: headerOffset,
                                 token: token)
        }
    }

    private func runTransactionalImport(batches: [String],
                                        totalRows: Int,
                                        token: CancellationToken) async {
        do {
            try await session.mysql.execute("START TRANSACTION")
            for (index, sql) in batches.enumerated() {
                if token.isCancelled { throw MySQLError.cancelled }
                try await session.mysql.execute(sql)
                processedRows = min(totalRows, (index + 1) * batchSize)
            }
            try await session.mysql.execute("COMMIT")
            successCount = totalRows
            processedRows = totalRows
        } catch {
            _ = try? await session.mysql.execute("ROLLBACK")
            let wasCancelled = token.isCancelled || (error as? MySQLError)?.isCancelled == true
            if wasCancelled {
                cancellationNotice = "导入已取消，已整体回滚，没有数据写入。"
            } else {
                failureCount = totalRows
                errorMessage = (error as? MySQLError)?.title ?? "导入失败"
            }
        }
    }

    private func runBatchImport(rows: [[String]],
                                batches: [String],
                                singles: [String],
                                headerOffset: Int,
                                token: CancellationToken) async {
        var stopped = false
        for (batchIndex, sql) in batches.enumerated() {
            if token.isCancelled || stopped { break }
            let start = batchIndex * batchSize
            let end = min(start + batchSize, rows.count)
            let range = start..<end
            do {
                try await session.mysql.execute(sql)
                successCount += range.count
            } catch {
                // 批失败：拆成单行，定位并记录失败行（最多 100 条）。
                for rowIndex in range {
                    if token.isCancelled || stopped { break }
                    guard rowIndex < singles.count else { continue }
                    do {
                        try await session.mysql.execute(singles[rowIndex])
                        successCount += 1
                    } catch {
                        recordFailure(rowIndex: rowIndex,
                                      row: rows[rowIndex],
                                      headerOffset: headerOffset,
                                      error: error)
                        if !continueOnError { stopped = true }
                    }
                }
            }
            processedRows = end
        }
        if token.isCancelled {
            cancellationNotice = "导入已取消，已导入的行保留。"
        } else if stopped {
            cancellationNotice = "遇到错误，已停止导入；之前已导入的行保留。"
        }
    }

    private func recordFailure(rowIndex: Int, row: [String], headerOffset: Int, error: Error) {
        failureCount += 1
        guard failures.count < 100 else { return }
        failures.append(CSVImporter.Failure(
            rowNumber: headerOffset + rowIndex + 1,
            content: row,
            message: (error as? MySQLError)?.title ?? "\(error)"
        ))
    }

    // MARK: 完成收尾

    /// 结束后刷新对应表标签（不新开标签），新表则顺带刷新对象树。
    func refreshTargetTable() async {
        guard let ref = currentTargetRef else { return }
        if targetMode == .newTable {
            await session.meta.invalidate(ref)
            await session.refreshObjects()
        }
        if let tab = session.tabs.first(where: { $0.kind == .tableData(ref) }),
           let model = tab.tableData as? TableDataViewModel {
            await model.reload()
        }
    }

    private var currentTargetRef: TableRef? {
        switch targetMode {
        case .existingTable:
            return targetRef
        case .newTable:
            let name = newTableName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : TableRef(database: database, table: name)
        }
    }

    // MARK: 失败行导出

    func exportFailures() {
        guard !failures.isEmpty else { return }
        let panel = NSSavePanel()
        if let csv = UTType(filenameExtension: "csv") {
            panel.allowedContentTypes = [csv]
        }
        panel.nameFieldStringValue = "导入失败行.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let columns = ["行号"] + sourceColumnNames + ["错误"]
        var lines = [CSVCodec.encodeRow(columns, delimiter: delimiter.character)]
        for failure in failures {
            var padded = failure.content
            if padded.count < sourceColumnNames.count {
                padded.append(contentsOf: Array(repeating: "", count: sourceColumnNames.count - padded.count))
            }
            if padded.count > sourceColumnNames.count {
                padded = Array(padded.prefix(sourceColumnNames.count))
            }
            let fields = ["\(failure.rowNumber)"] + padded + [failure.message]
            lines.append(CSVCodec.encodeRow(fields, delimiter: delimiter.character))
        }
        var data = Data(CSVCodec.byteOrderMark(for: .utf8BOM))
        data.append(Data((lines.joined(separator: "\n") + "\n").utf8))

        do {
            try fileSystem.writeAtomically(data, to: url, permissions: nil)
        } catch {
            logger.error("导出失败行失败：\(String(describing: error), privacy: .public)")
            errorMessage = "导出失败行失败：\(error.localizedDescription)"
        }
    }

    // MARK: 工具

    private static func dataTypeName(of rawType: String) -> String {
        let trimmed = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = trimmed.firstIndex(of: "(") {
            return String(trimmed[trimmed.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// 目标列下拉选项（跳过生成列）。
    var selectableTargetColumns: [TableColumn] {
        (targetStructure?.columns ?? []).filter { !$0.isGenerated }
    }
}
