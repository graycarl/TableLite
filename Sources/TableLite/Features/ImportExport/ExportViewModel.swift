import Foundation
import Observation

/// 导出面板的状态机。UI 只绑定这里的属性，真正的执行走 `CSVExportEngine`。
///
/// 需求见 `specs/08-import-export.md` §1，技术硬约束见
/// `docs/tech-designs/11-schema-and-import-export.md` §3。
@MainActor
@Observable
public final class ExportViewModel {

    // MARK: 源与配置

    public let source: ExportSource
    /// 面板顶部「源」下面的说明（含行数估算）。
    public private(set) var sourceDetail: String
    /// LIMIT 处理说明；nil 表示无需提示。
    public private(set) var limitNote: String?

    public var delimiter: CSVExportDelimiter
    public var lineEnding: CSVLineEnding
    public var includeHeader: Bool
    public var encoding: CSVTextEncoding
    public var nullRepresentation: CSVNullRepresentation
    /// 「日期格式」：原样输出 / 自定义（`specs/08-import-export.md` §1）。
    public var dateFormat: CSVDateFormat = .raw
    /// 「后台导出，完成后通知我」。执行始终在后台，勾选与否只影响完成后的告知方式。
    public var backgroundExport: Bool = true
    public var destinationURL: URL?

    // MARK: 进度

    public private(set) var phase: ExportPhase = .idle
    public private(set) var progress = ExportProgress(rowCount: 0, byteCount: 0)
    public private(set) var errorMessage: String?

    /// 完成后回调（主 session 用它做状态栏提示 / 通知）。第二个参数是「完成后通知我」开关。
    public var onFinish: ((ExportSummary, Bool) -> Void)?
    /// 进度回调；面板与状态栏共用同一份进度（`specs/12-feedback.md` §2）。
    public var onProgress: ((ExportProgress) -> Void)?

    // MARK: 依赖

    @ObservationIgnored private let session: ConnectionSession
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var control: ExportControl?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    // MARK: 初始化

    public init(session: ConnectionSession, source: ExportSource, preferences: Preferences) {
        self.session = session
        self.source = source
        self.preferences = preferences
        self.sourceDetail = source.detailText(rowCountEstimate: nil)
        self.delimiter = preferences.csvDelimiter
        self.lineEnding = preferences.csvLineEnding
        self.includeHeader = preferences.csvIncludeHeader
        self.encoding = preferences.csvEncoding
        self.nullRepresentation = preferences.csvNullRepresentation
        self.destinationURL = ImportExportFilePanels.defaultExportDirectory()
            .appendingPathComponent(source.suggestedFileName)
    }

    // MARK: 配置

    public func chooseDestination() {
        let suggested = destinationURL?.lastPathComponent ?? source.suggestedFileName
        if let picked = ImportExportFilePanels.chooseExportDestination(suggestedName: suggested) {
            destinationURL = picked
        }
    }

    public var writeOptions: CSVWriteOptions {
        CSVWriteOptions(
            delimiter: delimiter.byte,
            lineEnding: lineEnding,
            includeHeader: includeHeader,
            encoding: encoding,
            nullRepresentation: nullRepresentation
        )
    }

    // MARK: 执行

    public func start() {
        guard !phase.isRunning else { return }
        guard let destinationURL else {
            errorMessage = "请先选择保存位置"
            return
        }
        errorMessage = nil
        phase = .preparing

        let control = ExportControl()
        self.control = control
        let options = writeOptions
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runExport(destination: destinationURL, options: options, control: control)        }
    }

    public func cancel() {
        control?.cancel()
        phase = .preparing
        Task { try? await session.cancelCurrentQuery() }
    }

    /// 面板关闭前清理（取消进行中的导出）。
    public func dismiss() {
        runTask?.cancel()
        control?.cancel()
    }

    // MARK: 内部

    private func runExport(destination: URL, options: CSVWriteOptions, control: ExportControl) async {
        do {
            let plan = try await makePlan()
            limitNote = plan.limitNote
            sourceDetail = plan.sourceDetail

            let sink = try CSVExportSink(targetURL: destination, options: options)
            phase = .running
            onProgress?(progress)

            let summary = await CSVExportEngine.run(
                plan: plan,
                sink: sink,
                control: control,
                source: .session(session),
                dateFormatPattern: dateFormat.resolvedPattern,
                progress: { [weak self] rows, bytes in
                    Task { @MainActor in
                        let snapshot = ExportProgress(rowCount: rows, byteCount: bytes)
                        self?.progress = snapshot
                        self?.onProgress?(snapshot)
                    }
                }
            )

            progress = ExportProgress(rowCount: summary.rowCount, byteCount: summary.byteCount)
            errorMessage = summary.failureMessage
            phase = .done(summary)
            onFinish?(summary, backgroundExport)
        } catch {
            let message: String
            if let exportError = error as? CSVExportError {
                message = exportError.message
            } else {
                message = String(describing: error)
            }
            errorMessage = message
            let summary = ExportSummary(rowCount: progress.rowCount, byteCount: progress.byteCount, failureMessage: message)
            phase = .done(summary)
            onFinish?(summary, backgroundExport)
        }
    }

    private func makePlan() async throws -> ExportPlan {
        switch source {
        case .table(let database, let table):
            let structure = try await session.meta.structure(database: database, table: table, kind: .table)
            return ExportQueryPlanner.planTable(
                database: database,
                table: table,
                columns: structure.columns,
                primaryKeyColumns: structure.primaryKeyColumns.map(\.name),
                filterClause: nil,
                sourceDetail: source.detailText(rowCountEstimate: structure.table.rowCountEstimate)
            )

        case .filteredTable(let database, let table, let filterClause, _, _):
            let structure = try await session.meta.structure(database: database, table: table, kind: .table)
            return ExportQueryPlanner.planTable(
                database: database,
                table: table,
                columns: structure.columns,
                primaryKeyColumns: structure.primaryKeyColumns.map(\.name),
                filterClause: filterClause,
                sourceDetail: source.detailText(rowCountEstimate: structure.table.rowCountEstimate)
            )

        case .selectedRows(let database, let table, let whereClause, let rowCount):
            let structure = try await session.meta.structure(database: database, table: table, kind: .table)
            return ExportQueryPlanner.planSelectedRows(
                database: database,
                table: table,
                columns: structure.columns,
                whereClause: whereClause,
                rowCount: rowCount
            )

        case .queryResult(let sql, let description):
            return ExportQueryPlanner.planQuery(sql: sql, description: description)
        }
    }
}
