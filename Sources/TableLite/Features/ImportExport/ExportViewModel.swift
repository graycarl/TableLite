import AppKit
import Combine
import Foundation
import os
import Synchronization
import UniformTypeIdentifiers

// MARK: - 导出 ViewModel
//
// 见 specs/08-import-export.md §1、docs/tech-designs/11-schema-and-import-export.md §3。
//
// 硬约束（docs/11 §3.1）：导出绝不先把数据全读进内存——用 `MySQLSession.query(_:unbuffered:)`
// 的逐行事件流喂给 `CSVExporter.write` 边收边写；写临时文件成功后原子替换目标；
// 取消 / 中断时保留已写内容为 `.partial`。
//
// 线程：整个类型 `@MainActor`；所有 `@Published` 写入都在主线程；
// 数据库访问 `await` 到 `MySQLSession`（actor）。
@MainActor
final class ExportViewModel: ObservableObject {

    // MARK: 导出源

    // TODO(Wave 5b)：结果标签右键「导出结果…」与网格右键「导出选中行…」的菜单分别位于
    // `Features/QueryEditor/QueryTabView.swift` 与 `Features/DataGridView.swift`（本 wave 不改这两个文件）。
    // 接线方式：构造 `.queryResult(sql:columns:knownRowCount:)` / `.selectedRows(ref:structure:locators:fallbackRows:)`
    // 的 `ExportSheetRequest`，再用 `ExportPanelView(...)` 以 sheet 呈现。

    /// 一次导出的数据来源。
    enum Source: Sendable {
        /// 整表 / 当前过滤条件下的全部数据。
        case table(ref: TableRef, filter: FilterSet, sort: [SortDescriptor])
        /// 查询结果集：原 SQL（尝试剥掉顶层 LIMIT）。
        case queryResult(sql: String, columns: [ResultSetColumn], knownRowCount: UInt64?)
        /// 选中行：按行定位键拼 WHERE；无主键时回退到内存里的选中行。
        case selectedRows(ref: TableRef,
                          structure: TableStructure,
                          locators: [RowLocator],
                          fallbackRows: [[CellValue]])
    }

    struct Completion: Equatable, Sendable {
        var rowCount: Int
        var byteCount: Int
        var fileURL: URL

        var fileName: String { fileURL.lastPathComponent }
    }

    enum Failure: Equatable, Sendable {
        case cancelled(partialURL: URL?)
        case interrupted(partialURL: URL?)
        case destinationNotWritable(String)
        case queryFailure(MySQLError)
        case other(String)

        var title: String {
            switch self {
            case .cancelled: return "导出已取消"
            case .interrupted: return "导出中断，文件不完整"
            case .destinationNotWritable: return "目标文件不可写"
            case .queryFailure(let error): return error.title
            case .other: return "导出失败"
            }
        }

        /// 数据现在是什么状态（specs/12 §5 规则 3）。
        var stateMessage: String {
            switch self {
            case .cancelled(let partial), .interrupted(let partial):
                if let partial {
                    return "已写入的部分保留为 \(partial.lastPathComponent)，该文件不完整。"
                }
                return "已写入的部分不完整，请勿使用。"
            case .destinationNotWritable(let reason):
                return reason
            case .queryFailure:
                return "导出未完成，目标文件未生成。"
            case .other:
                return "导出未完成，目标文件未生成。"
            }
        }

        var serverError: MySQLServerError? {
            if case .queryFailure(let error) = self { return error.serverError }
            return nil
        }
    }

    // MARK: 依赖

    private let source: Source
    private let session: ConnectionSession
    private let fileSystem: FileSystemLocator
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    // MARK: 状态

    @Published var options: CSVCodec.Options
    @Published private(set) var destination: URL?
    /// 勾选后导出在后台进行，完成后用轻提示通知（面板自动关闭）。
    @Published var runsInBackground = true

    @Published private(set) var isPreparing = false
    @Published private(set) var isExporting = false
    @Published private(set) var prepared = false
    @Published private(set) var header: [String] = []
    @Published private(set) var estimatedRows: UInt64?
    @Published private(set) var sourceDetail: String?
    @Published private(set) var prepareError: String?

    @Published private(set) var writtenRows = 0
    @Published private(set) var writtenBytes = 0

    @Published private(set) var completion: Completion?
    @Published private(set) var failure: Failure?

    // MARK: 私有

    private var structure: TableStructure?
    private var exportTask: Task<Void, Never>?
    private var cancellationToken: CancellationToken?
    /// 轻提示中心（导出完成 / 在 Finder 中显示）。视图出现时通过 ``attach(toasts:)`` 注入。
    private var toasts: ToastCenter?

    // MARK: 初始化

    init(source: Source,
         session: ConnectionSession,
         fileSystem: FileSystemLocator,
         preferences: PreferencesStore) {
        self.source = source
        self.session = session
        self.fileSystem = fileSystem

        var options = CSVCodec.Options()
        options.delimiter = preferences.csvDelimiter.character
        options.lineEnding = preferences.csvLineEnding
        options.includeHeader = preferences.csvIncludeHeader
        options.encoding = preferences.csvEncoding
        options.nullStyle = preferences.csvNullStyle
        self.options = options
    }

    // MARK: 展示文案

    var sourceName: String {
        switch source {
        case .table(let ref, _, _):
            return ref.displayName
        case .queryResult:
            return "查询结果"
        case .selectedRows(let ref, _, _, _):
            return "\(ref.displayName)（选中行）"
        }
    }

    var suggestedFileName: String {
        switch source {
        case .table(let ref, _, _):
            return "\(ref.table).csv"
        case .queryResult:
            return "查询结果.csv"
        case .selectedRows(let ref, _, _, _):
            return "\(ref.table)-选中行.csv"
        }
    }

    var rowCountText: String {
        guard let estimatedRows else { return "行数未知" }
        return "约 \(TableDataViewModelLogic.groupedDigits(Int(clamping: estimatedRows))) 行"
    }

    var destinationText: String {
        destination?.path ?? "尚未选择保存位置"
    }

    var progressText: String {
        "正在导出… 已写入 \(TableDataViewModelLogic.groupedDigits(writtenRows)) 行"
            + "（\(Self.byteText(writtenBytes))）"
    }

    var canExport: Bool {
        destination != nil && !isExporting && !isPreparing && prepareError == nil
    }

    // MARK: 准备

    /// 注入轻提示中心。导出完成时由本对象直接提示，因此「后台导出」勾选后面板
    /// 先关闭也能正常收到通知。
    func attach(toasts: ToastCenter) {
        self.toasts = toasts
    }

    /// 面板出现时调用：加载表结构 / 行数估算 / 结果集提示。
    func prepare() async {
        guard !prepared, !isPreparing else { return }
        isPreparing = true
        prepareError = nil
        defer {
            isPreparing = false
            prepared = true
        }

        switch source {
        case .table(let ref, let filter, _):
            do {
                let loaded = try await session.meta.structure(ref)
                structure = loaded
                header = loaded.columns.map(\.name)
                estimatedRows = try? await session.meta.rowEstimate(ref)
                sourceDetail = ExportSQL.filterSummary(filter).map { "应用了过滤条件：\($0)" }
            } catch {
                logger.error("导出前读取表结构失败：\(String(describing: error), privacy: .public)")
                prepareError = (error as? MySQLError)?.title ?? "读取表结构失败"
            }

        case .queryResult(let sql, let columns, let known):
            header = columns.map(\.name)
            estimatedRows = known
            if ExportSQL.stripTopLevelLimit(sql).isAmbiguous {
                if let known {
                    sourceDetail = "该查询带 LIMIT 且无法安全改写，将导出本次实际返回的 \(known) 行"
                } else {
                    sourceDetail = "该查询带 LIMIT 且无法安全改写，将导出本次实际返回的行"
                }
            }

        case .selectedRows(_, let loaded, let locators, let fallbackRows):
            structure = loaded
            header = loaded.columns.map(\.name)
            let usableLocators = !locators.isEmpty && locators.allSatisfy { !$0.isEmpty }
            estimatedRows = UInt64(usableLocators ? locators.count : fallbackRows.count)
        }
    }

    // MARK: 交互

    func chooseDestination() {
        let panel = NSSavePanel()
        if let csv = UTType(filenameExtension: "csv") {
            panel.allowedContentTypes = [csv]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = destination?.lastPathComponent ?? suggestedFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }

    func start() {
        guard !isExporting else { return }
        guard let destination else {
            failure = .destinationNotWritable("请先选择保存位置")
            return
        }

        failure = nil
        completion = nil
        writtenRows = 0
        writtenBytes = 0
        isExporting = true

        let token = CancellationToken()
        cancellationToken = token
        let header = self.header
        let options = self.options
        let fileSystem = self.fileSystem

        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isExporting = false
                self.exportTask = nil
                self.cancellationToken = nil
            }
            do {
                let rows = try await self.makeRowStream()
                let exporter = CSVExporter(fileSystem: fileSystem, options: options)
                try await exporter.write(
                    to: destination,
                    header: header,
                    rows: rows,
                    onProgress: { rows, bytes in
                        Task { @MainActor [weak self] in
                            self?.updateProgress(rows: rows, bytes: bytes)
                        }
                    },
                    cancellation: { token.isCancelled }
                )
                self.completion = Completion(rowCount: self.writtenRows,
                                             byteCount: self.writtenBytes,
                                             fileURL: destination)
                self.postCompletion(destination: destination,
                                    rowCount: self.writtenRows)
            } catch let error as CSVExportError {
                switch error {
                case .incomplete(let partial):
                    self.failure = token.isCancelled
                        ? .cancelled(partialURL: partial)
                        : .interrupted(partialURL: partial)
                case .destinationNotWritable(let reason):
                    self.failure = .destinationNotWritable(reason)
                }
            } catch {
                self.logger.error("导出失败：\(String(describing: error), privacy: .public)")
                if token.isCancelled {
                    self.failure = .cancelled(partialURL: nil)
                } else if let mysqlError = error as? MySQLError {
                    self.failure = .queryFailure(mysqlError)
                } else {
                    self.failure = .other(String(describing: error))
                }
            }
        }
    }

    /// 取消导出：置本地标志、取消任务，并中断正在跑的查询。
    func cancel() {
        cancellationToken?.request()
        exportTask?.cancel()
        Task { await session.mysql.cancelCurrentQuery() }
    }

    func clearFailure() { failure = nil }

    // MARK: 流式行来源

    private func makeRowStream() async throws -> AsyncThrowingStream<[CellValue], Error> {
        if !prepared { await prepare() }
        if let prepareError {
            throw MySQLError.unsupported(prepareError)
        }

        switch source {
        case .table(let ref, let filter, let sort):
            guard let structure else {
                throw MySQLError.unsupported("表结构尚未加载完成")
            }
            let literalizer = await session.mysql.literalizer()
            let sql = try TableDataQueryBuilder.exportSQL(
                ref: ref,
                structure: structure,
                filter: filter,
                sort: sort,
                literalizer: literalizer
            )
            return await streamQuery(sql)

        case .queryResult(let sql, _, _):
            // 无法安全剥掉 LIMIT 时不改 SQL（L2）。
            return await streamQuery(ExportSQL.stripTopLevelLimit(sql).sql)

        case .selectedRows(let ref, let loaded, let locators, let fallbackRows):
            let usableLocators = !locators.isEmpty && locators.allSatisfy { !$0.isEmpty }
            if usableLocators {
                let literalizer = await session.mysql.literalizer()
                if let sql = ExportSQL.selectedRowsSQL(ref: ref,
                                                       structure: loaded,
                                                       locators: locators,
                                                       literalizer: literalizer) {
                    return await streamQuery(sql)
                }
            }
            return inMemoryStream(fallbackRows)
        }
    }

    /// `MySQLSession` 的逐事件流 → 逐行值流。仅 `.row` 事件产出数据。
    private func streamQuery(_ sql: String) async -> AsyncThrowingStream<[CellValue], Error> {
        let events = await session.mysql.query(sql, unbuffered: true)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .row(_, _, let values) = event {
                            continuation.yield(values)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func inMemoryStream(_ rows: [[CellValue]]) -> AsyncThrowingStream<[CellValue], Error> {
        AsyncThrowingStream { continuation in
            for row in rows { continuation.yield(row) }
            continuation.finish()
        }
    }

    private func updateProgress(rows: Int, bytes: Int) {
        writtenRows = max(writtenRows, rows)
        writtenBytes = max(writtenBytes, bytes)
    }

    private func postCompletion(destination: URL, rowCount: Int) {
        let text = "导出完成：\(TableDataViewModelLogic.groupedDigits(rowCount)) 行"
            + " → \(destination.lastPathComponent)"
        toasts?.show(text, actionTitle: "在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    // MARK: 工具

    static func byteText(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0))
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(Int(value)) \(units[index])"
        }
        return String(format: "%.1f %@", value, units[index])
    }
}

// MARK: - 取消标志

/// 跨导入 / 导出任务与取消按钮共享的取消标志。
/// 用 `Mutex` 保证线程安全，因此是正常的 `Sendable`（无需 `@unchecked`）。
final class CancellationToken: Sendable {

    private let flag = Mutex(false)

    func request() { flag.withLock { $0 = true } }

    var isCancelled: Bool { flag.withLock { $0 } }
}
