import Combine
import Foundation
import os

// MARK: - 查询进度

/// 一次执行的实时进度（结果区状态栏用）。见 docs/tech-designs/10-query-editor.md §5.3。
struct QueryProgress: Hashable {
    var rows: Int = 0
    var bytes: Int = 0
    var elapsed: Duration = .zero
}

// MARK: - 单条语句的结果

/// 一条已下发（或被只读拦截）语句的结果标签。
///
/// 契约：`docs/tech-designs/10-query-editor.md` §5.2 / §6、`specs/06-query-editor.md` §3–§4。
/// `id` 单调递增，标签关闭后不复用；`title` 取 `结果 N` / `完成` / `错误` / `只读拦截`。
struct QueryResult: Identifiable, Hashable {
    enum Kind {
        /// 首个结果集（含列元数据与内存行）。`CALL` 等多结果集语句只呈现首个。
        case rows(MaterializedResultSet)
        /// 没有结果集：影响行数 + last_insert_id。
        case affected(ResultSetHeader)
        /// 服务器返回的单语句错误。
        case error(MySQLServerError)
        /// 只读模式拦截，`String` 是给用户看的原因。
        case rejected(String)
    }

    var id: Int
    var statement: String
    var kind: Kind
    var elapsed: Duration
    /// `结果 1` / `完成` / `错误` / `只读拦截`
    var title: String

    static let completedTitle = "完成"
    static let errorTitle = "错误"
    static let rejectedTitle = "只读拦截"

    static func rowsTitle(_ number: Int) -> String { "结果 \(number)" }

    var rowCount: Int? {
        if case .rows(let set) = kind { return set.rows.count }
        return nil
    }

    var affectedRows: Int? {
        if case .affected(let header) = kind { return Int(header.affectedRows) }
        return nil
    }

    var errorCode: UInt32? {
        if case .error(let error) = kind { return error.code }
        return nil
    }
}

// `MaterializedResultSet` 在 Core 里只声明了 `Sendable`，这里给它补 `Hashable`
// 的等价实现，避免为了一个 UI 模型去改动 Core/Model/QueryModel.swift。
extension QueryResult.Kind: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.rows(a), .rows(b)):
            return a.header == b.header && a.rows == b.rows
        case let (.affected(a), .affected(b)):
            return a == b
        case let (.error(a), .error(b)):
            return a == b
        case let (.rejected(a), .rejected(b)):
            return a == b
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .rows(let set):
            hasher.combine(0)
            hasher.combine(set.header)
            hasher.combine(set.rows)
        case .affected(let header):
            hasher.combine(1)
            hasher.combine(header)
        case .error(let error):
            hasher.combine(2)
            hasher.combine(error)
        case .rejected(let reason):
            hasher.combine(3)
            hasher.combine(reason)
        }
    }
}

// MARK: - 可单元测试的纯逻辑

/// 与 UI 无关的查询标签逻辑：光标选语句、状态栏文案、错误合成。
/// 见 `Tests/TableLiteTests/Unit/QueryTabLogicTests.swift`。
enum QueryTabLogic {

    /// 光标（UTF-16 offset）落在哪条语句里。
    ///
    /// split 产出的 range 是 UTF-16 单位，与 `NSTextView.selectedRange` / `cursorLocation` 一致。
    /// 语句 range 连续（前一条含分号），落在空白处的光标会归到后一条；文档末尾归到末条。
    static func statementIndex(atCursor location: Int, in statements: [SQLStatement]) -> Int? {
        guard !statements.isEmpty else { return nil }
        for (index, statement) in statements.enumerated() {
            let start = statement.range.location
            let end = start + statement.range.length
            if location >= start && location < end { return index }
        }
        var best: Int?
        for (index, statement) in statements.enumerated() where statement.range.location <= location {
            best = index
        }
        return best ?? 0
    }

    /// `已执行 3 条语句 · 耗时 42 ms · 返回 1,204 行`。
    static func statusSummary(for results: [QueryResult]) -> String {
        guard !results.isEmpty else { return "就绪" }

        let executed = results.filter { if case .rejected = $0.kind { return false }; return true }
        let rejected = results.count - executed.count
        let elapsed = results.reduce(Duration.zero) { $0 + $1.elapsed }
        let rows = results.reduce(0) { $0 + ($1.rowCount ?? 0) }
        let affected = results.reduce(0) { $0 + ($1.affectedRows ?? 0) }

        var parts = ["已执行 \(executed.count) 条语句", "耗时 \(elapsedText(elapsed))"]
        if rows > 0 {
            parts.append("返回 \(grouped(rows)) 行")
        } else if affected > 0 {
            parts.append("影响 \(grouped(affected)) 行")
        }
        if rejected > 0 {
            parts.append("只读拦截 \(rejected) 条")
        }
        return parts.joined(separator: " · ")
    }

    /// 把取消 / 超时 / 连接断开的 `MySQLError` 合成为可放进结果标签的错误。
    static func syntheticError(for error: MySQLError) -> MySQLServerError {
        switch error {
        case .cancelled:
            return MySQLServerError(code: 1317, sqlState: "70100", message: "查询已取消", sql: nil)
        case .timeout:
            return MySQLServerError(code: 3024, sqlState: "HY000", message: "查询超时", sql: nil)
        case .connectionLost(let serverError):
            return serverError ?? MySQLServerError(code: 2006, sqlState: "HY000",
                                                   message: "连接已断开", sql: nil)
        case .notConnected:
            return MySQLServerError(code: 2006, sqlState: "HY000", message: "尚未连接数据库", sql: nil)
        case .server(let serverError):
            return serverError
        case .connect(_, let message, _):
            return MySQLServerError(code: 0, sqlState: "", message: message, sql: nil)
        case .unsupported(let text):
            return MySQLServerError(code: 0, sqlState: "", message: text, sql: nil)
        case .internalError(let text):
            return MySQLServerError(code: 0, sqlState: "", message: text, sql: nil)
        }
    }

    /// 千分位分组，例如 `1204` → `1,204`。纯函数，避免依赖非 Sendable 的 NumberFormatter。
    static func grouped(_ value: Int) -> String {
        guard value != 0 else { return "0" }
        let negative = value < 0
        var digits = String(value.magnitude)
        var grouped = ""
        while digits.count > 3 {
            let split = digits.index(digits.endIndex, offsetBy: -3)
            grouped = "," + digits[split...] + grouped
            digits = String(digits[..<split])
        }
        grouped = digits + grouped
        return negative ? "-" + grouped : grouped
    }

    /// `42 ms`（小于 1ms 显示 `<1 ms`）。
    static func elapsedText(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1e15
        if milliseconds < 1 { return "<1 ms" }
        return "\(grouped(Int(milliseconds.rounded()))) ms"
    }
}

// MARK: - QueryTabViewModel

/// 单个查询标签的 ViewModel：编辑器内容、执行、结果标签、草稿。
///
/// 边界：
/// - 只通过 `MySQLSession` 访问数据库（不 `import CMySQLClient`）；
/// - 不引用 `ConnectionSession` / `Tab` / `AppEnvironment`，由 View 注入所需依赖；
/// - 只读拦截在**下发前逐条**进行（`docs/tech-designs/10-query-editor.md` §10）。
///
/// 执行模型：按拆分结果逐条 `session.query(_, unbuffered: true)`，攒批（200 行）写入 `results`，
/// 每条语句形成自己的结果标签（同上 §5.2 / §6）。
@MainActor
final class QueryTabViewModel: ObservableObject {

    // MARK: 依赖

    let connectionID: UUID
    let draftID: UUID
    let isReadOnly: Bool

    private let session: MySQLSession
    private let preferences: PreferencesStore
    private let history: HistoryRepository
    private let consoleLog: ConsoleLogStore
    private let drafts: DraftStore
    private let clock: Clock
    private let database: String?

    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "mysql")

    /// 流式结果每攒够这么多行就刷新一次结果区。
    private static let batchSize = 200

    // MARK: 编辑器内容

    @Published var sql: String {
        didSet {
            guard !isRestoringDraft else { return }
            scheduleDraftSave()
        }
    }

    @Published var fileURL: URL?

    /// `NSTextView` 回写的选区（UTF-16）。
    @Published var selectedRange: NSRange = .init(location: 0, length: 0)

    /// `NSTextView` 回写的光标位置（UTF-16）。
    @Published var cursorLocation: Int = 0

    /// 已关联文件且内容与磁盘上的基线不同。
    var hasUnsavedFileChanges: Bool {
        guard fileURL != nil else { return false }
        return sql != (savedFileContents ?? "")
    }

    private var savedFileContents: String?
    private var isRestoringDraft = false

    // MARK: 执行状态

    @Published private(set) var isExecuting = false
    @Published private(set) var progress = QueryProgress()
    @Published private(set) var results: [QueryResult] = []
    @Published var activeResultIndex: Int = 0
    @Published private(set) var statusSummary = "就绪"

    private var nextResultID = 0
    private var stopRequested = false

    private var draftTask: Task<Void, Never>?
    private var progressTicker: Task<Void, Never>?

    // MARK: init

    init(connectionID: UUID,
         database: String?,
         session: MySQLSession,
         isReadOnly: Bool,
         preferences: PreferencesStore,
         history: HistoryRepository,
         consoleLog: ConsoleLogStore,
         drafts: DraftStore,
         clock: Clock,
         draftID: UUID,
         initialSQL: String,
         fileURL: URL?) {
        self.connectionID = connectionID
        self.database = (database?.isEmpty == false) ? database : nil
        self.session = session
        self.isReadOnly = isReadOnly
        self.preferences = preferences
        self.history = history
        self.consoleLog = consoleLog
        self.drafts = drafts
        self.clock = clock
        self.draftID = draftID
        self.sql = initialSQL
        self.fileURL = fileURL
        self.savedFileContents = fileURL != nil ? initialSQL : nil
    }

    // MARK: 执行入口

    /// `⌘↩`：有选区执行选中文本，否则执行光标所在语句。
    func executeCurrent() async {
        let statements: [SQLStatement]
        if selectedRange.length > 0 {
            let editor = sql as NSString
            let range = selectedRange
            guard range.location >= 0, NSMaxRange(range) <= editor.length else {
                logger.warning("选区越界，忽略本次执行")
                return
            }
            statements = StatementSplitter.split(editor.substring(with: range))
        } else {
            let all = StatementSplitter.split(sql)
            if let index = QueryTabLogic.statementIndex(atCursor: cursorLocation, in: all) {
                statements = [all[index]]
            } else {
                statements = []
            }
        }
        await run(statements)
    }

    /// `⇧⌘↩`：执行全部语句。
    func executeAll() async {
        await run(StatementSplitter.split(sql))
    }

    /// 停止当前执行。已收到的部分结果保留展示。
    func stop() {
        guard isExecuting else { return }
        stopRequested = true
        Task { await session.cancelCurrentQuery() }
    }

    // MARK: 草稿

    /// 编辑后防抖 1s 落盘；`editorAutoSaveDrafts` 关闭时不做任何事。
    func scheduleDraftSave() {
        draftTask?.cancel()
        guard preferences.editorAutoSaveDrafts else { return }
        draftTask = Task { [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(seconds: 1)
            guard !Task.isCancelled else { return }
            await self.saveDraftNow()
        }
    }

    func saveDraftNow() async {
        do {
            try drafts.save(sql, draftID: draftID)
        } catch {
            logger.error("保存草稿失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// `restoreDrafts` 关闭时不动编辑器；编辑器已有内容（例如从文件打开）时也不覆盖。
    func loadDraft() async {
        guard preferences.restoreDrafts, sql.isEmpty else { return }
        do {
            guard let text = try drafts.load(draftID: draftID) else { return }
            isRestoringDraft = true
            sql = text
            isRestoringDraft = false
        } catch {
            logger.error("读取草稿失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 文件保存成功后由 View 调用，重置「未保存改动」基线。
    func markFileSaved() {
        savedFileContents = sql
    }

    /// 关联 / 另存为新文件后由 View 调用，重置基线。
    func setFile(_ url: URL?) {
        fileURL = url
        savedFileContents = url != nil ? sql : nil
    }

    // MARK: 执行实现

    private func run(_ statements: [SQLStatement]) async {
        guard !isExecuting else { return }
        guard !statements.isEmpty else {
            statusSummary = "没有可执行的语句"
            return
        }

        isExecuting = true
        stopRequested = false
        results = []
        activeResultIndex = 0
        nextResultID = 0
        progress = QueryProgress()
        let runStart = clock.now
        startProgressTicker(since: runStart)

        defer {
            progressTicker?.cancel()
            progressTicker = nil
            progress.elapsed = Duration.seconds(clock.now.timeIntervalSince(runStart))
            isExecuting = false
            statusSummary = QueryTabLogic.statusSummary(for: results)
        }

        for statement in statements {
            if stopRequested { break }

            if isReadOnly, case .rejected(let reason) = ReadOnlyGuard.evaluate(statement) {
                appendRejected(statement: statement, reason: reason)
                continue
            }

            let shouldContinue = await executeStatement(statement)
            if !shouldContinue { break }
        }
    }

    /// 执行单条语句，返回是否继续下发后续语句。
    private func executeStatement(_ statement: SQLStatement) async -> Bool {
        let sql = statement.text
        let start = clock.now

        var firstHeader: ResultSetHeader?
        var collectedRows: [[CellValue]] = []
        var okHeader: ResultSetHeader?
        var firstError: MySQLServerError?
        var thrown: MySQLError?
        var streamingIndex: Int?
        var rowsTitle: String?

        let stream = await session.query(sql, unbuffered: true)
        do {
            for try await event in stream {
                switch event {
                case .resultSet(let header):
                    if header.isResultSet {
                        if firstHeader == nil {
                            firstHeader = header
                            let title = nextRowsTitle()
                            rowsTitle = title
                            results.append(QueryResult(
                                id: nextResultID,
                                statement: sql,
                                kind: .rows(MaterializedResultSet(header: header, rows: [])),
                                elapsed: .zero,
                                title: title
                            ))
                            nextResultID += 1
                            streamingIndex = results.count - 1
                            activeResultIndex = streamingIndex ?? activeResultIndex
                        } else {
                            // 多结果集（CALL 等）：本 VM 每个语句只呈现首个结果集。
                            logger.info("语句返回了多个结果集，只展示首个：\(statement.firstKeyword, privacy: .public)")
                        }
                    } else if okHeader == nil {
                        okHeader = header
                    }

                case .row(let resultIndex, _, let values):
                    guard resultIndex == 0, let header = firstHeader else { continue }
                    collectedRows.append(values)
                    progress.rows += 1
                    progress.bytes += values.reduce(0) { $0 + $1.byteCount }
                    progress.elapsed = Duration.seconds(clock.now.timeIntervalSince(start))
                    if collectedRows.count % Self.batchSize == 0, let index = streamingIndex {
                        results[index] = QueryResult(
                            id: results[index].id,
                            statement: sql,
                            kind: .rows(MaterializedResultSet(header: header, rows: collectedRows)),
                            elapsed: Duration.seconds(clock.now.timeIntervalSince(start)),
                            title: rowsTitle ?? results[index].title
                        )
                    }

                case .statementError(_, let error):
                    if firstError == nil { firstError = error }

                case .finished:
                    break
                }
            }
        } catch let error as MySQLError {
            thrown = error
        } catch {
            thrown = .internalError(String(describing: error))
        }

        let elapsed = Duration.seconds(clock.now.timeIntervalSince(start))

        var succeeded = true
        var rowCount: Int?
        var affectedRows: Int?
        var errorCode: UInt32?
        var errorMessage: String?
        let finalKind: QueryResult.Kind

        if let firstError {
            succeeded = false
            errorCode = firstError.code
            errorMessage = firstError.message
            finalKind = .error(firstError)
        } else if let thrown {
            let synthetic = QueryTabLogic.syntheticError(for: thrown)
            succeeded = false
            errorCode = synthetic.code
            errorMessage = synthetic.message
            if let header = firstHeader, thrown.isCancelled || thrown == .timeout {
                // 停止 / 超时：保留已收到的部分结果。
                rowCount = collectedRows.count
                finalKind = .rows(MaterializedResultSet(header: header, rows: collectedRows))
            } else {
                finalKind = .error(synthetic)
            }
        } else if let header = firstHeader {
            rowCount = collectedRows.count
            finalKind = .rows(MaterializedResultSet(header: header, rows: collectedRows))
        } else if let header = okHeader {
            affectedRows = Int(header.affectedRows)
            finalKind = .affected(header)
        } else {
            affectedRows = 0
            finalKind = .affected(ResultSetHeader(index: 0, columns: [],
                                                  affectedRows: 0, lastInsertID: 0))
        }

        let finalTitle: String
        switch finalKind {
        case .rows: finalTitle = rowsTitle ?? QueryResult.rowsTitle(1)
        case .affected: finalTitle = QueryResult.completedTitle
        case .error: finalTitle = QueryResult.errorTitle
        case .rejected: finalTitle = QueryResult.rejectedTitle
        }

        if let index = streamingIndex {
            results[index] = QueryResult(
                id: results[index].id,
                statement: sql,
                kind: finalKind,
                elapsed: elapsed,
                title: finalTitle
            )
        } else {
            results.append(QueryResult(
                id: nextResultID,
                statement: sql,
                kind: finalKind,
                elapsed: elapsed,
                title: finalTitle
            ))
            nextResultID += 1
            activeResultIndex = results.count - 1
        }

        recordHistory(sql: sql, succeeded: succeeded, elapsed: elapsed,
                      rowCount: rowCount, affectedRows: affectedRows, errorCode: errorCode)
        recordConsole(sql: sql, elapsed: elapsed, rowCount: rowCount,
                      affectedRows: affectedRows, errorCode: errorCode, errorMessage: errorMessage)

        return shouldContinue(after: thrown, statementError: firstError)
    }

    /// 出错后是否继续下发后续语句：`editorStopOnError` 默认 true。
    private func shouldContinue(after thrown: MySQLError?, statementError: MySQLServerError?) -> Bool {
        if stopRequested { return false }
        if let thrown {
            switch thrown {
            case .cancelled, .connectionLost, .notConnected:
                return false
            default:
                break
            }
        }
        if thrown != nil || statementError != nil {
            return !preferences.editorStopOnError
        }
        return true
    }

    // MARK: 结果辅助

    private func appendRejected(statement: SQLStatement, reason: String) {
        results.append(QueryResult(
            id: nextResultID,
            statement: statement.text,
            kind: .rejected(reason),
            elapsed: .zero,
            title: QueryResult.rejectedTitle
        ))
        nextResultID += 1
        activeResultIndex = results.count - 1
    }

    private func nextRowsTitle() -> String {
        let count = results.reduce(0) { partial, result in
            if case .rows = result.kind { return partial + 1 }
            return partial
        }
        return QueryResult.rowsTitle(count + 1)
    }

    private func startProgressTicker(since start: Date) {
        progressTicker?.cancel()
        progressTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.clock.sleep(seconds: 0.2)
                guard !Task.isCancelled else { return }
                self.progress.elapsed = Duration.seconds(self.clock.now.timeIntervalSince(start))
            }
        }
    }

    // MARK: 历史 / Console Log

    private func recordHistory(sql: String, succeeded: Bool, elapsed: Duration,
                               rowCount: Int?, affectedRows: Int?, errorCode: UInt32?) {
        do {
            try history.record(HistoryRepository.NewEntry(
                connectionID: connectionID,
                database: database,
                sql: sql,
                succeeded: succeeded,
                elapsed: elapsed,
                rowCount: rowCount,
                affectedRows: affectedRows,
                errorCode: errorCode,
                executedAt: clock.now
            ))
        } catch {
            logger.error("写入查询历史失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// Console Log 记录**所有**下发语句；本 VM 只发 `[data]`（用户发起）。
    private func recordConsole(sql: String, elapsed: Duration, rowCount: Int?,
                               affectedRows: Int?, errorCode: UInt32?, errorMessage: String?) {
        consoleLog.append(ConsoleLogStore.Entry(
            timestamp: clock.now,
            category: .data,
            database: database,
            sql: sql,
            elapsed: elapsed,
            rowCount: rowCount,
            affectedRows: affectedRows,
            errorCode: errorCode,
            errorMessage: errorMessage
        ))
    }
}
