import Foundation
import Observation
import AppKit

/// 查询标签（SQL 编辑器）的 ViewModel。
///
/// 状态归属见 `docs/tech-designs/06-ui-layer.md` §2：每个标签的 ViewModel 由标签自己持有。
/// 所有数据库访问经 `ConnectionSession.execute`（自动记查询历史 + Console Log + DDL 缓存失效），
/// **不另写一套记录路径**。见 `docs/tech-designs/10-query-editor.md` §5/§7/§8。
@MainActor
@Observable
final class QueryEditorViewModel {

    // MARK: 标识

    let session: ConnectionSession
    let tab: Tab
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let drafts: QueryDraftStore
    @ObservationIgnored private let clock: Clock

    // MARK: 文本与光标

    var text: String = ""
    private(set) var selectedRange = NSRange(location: 0, length: 0)
    /// `⌘F` 请求计数器：变化时编辑器弹出系统查找条。
    private(set) var findRequestToken = 0
    /// 注释切换 / 缩进 / 反缩进命令。
    private(set) var editorCommand: SQLTextViewCommand?
    @ObservationIgnored private var commandToken = 0

    // MARK: 结果

    private(set) var results: [QueryResultTab] = []
    var selectedResultID: UUID?

    // MARK: 执行状态

    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var elapsedMilliseconds = 0
    private(set) var executedStatementCount = 0
    private(set) var totalReturnedRows = 0
    /// 轻提示（只读跳过写操作等）。
    private(set) var notice: String?
    /// 执行中已接收行数（缓冲执行路径下与最终行数一致）。
    private(set) var receivedRowCount = 0
    /// 执行中已接收的近似字节数（状态栏 `已接收 X 行（Y MB）`，`specs/06-query-editor.md` §3）。
    private(set) var receivedByteCount = 0
    /// 大结果提示（L1）。
    private(set) var showsLargeResultHint = false

    // MARK: 文件

    private(set) var filePath: String?
    private(set) var isDirty = false

    // MARK: 内部

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(
        session: ConnectionSession,
        tab: Tab,
        preferences: Preferences,
        drafts: QueryDraftStore,
        clock: Clock
    ) {
        self.session = session
        self.tab = tab
        self.preferences = preferences
        self.drafts = drafts
        self.clock = clock
        self.filePath = tab.filePath
    }

    // MARK: 生命周期

    /// 首次进入标签：装配初始内容（打开脚本带入 / 草稿恢复）。
    func start() async {
        guard !didStart else { return }
        didStart = true
        if let initial = tab.initialSQL {
            text = initial
            isDirty = false
            tab.initialSQL = nil
            return
        }
        if preferences.restoreLastScript, let draftID = tab.kind.draftID,
           let draft = try? await drafts.read(id: draftID) {
            text = draft
        }
    }

    /// 离开标签：停掉在途任务并落一次草稿。
    func stopInFlight() {
        if isRunning {
            stop()
        }
        draftTask?.cancel()
        elapsedTask?.cancel()
        flushDraft()
    }

    // MARK: 文本变化

    func textChanged(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = true
        scheduleDraftSave()
    }

    func selectionChanged(_ range: NSRange) {
        selectedRange = range
    }

    func requestFind() {
        findRequestToken += 1
    }

    func requestCommand(_ command: SQLEditingCommand) {
        commandToken += 1
        editorCommand = SQLTextViewCommand(token: commandToken, command: command)
    }

    // MARK: 执行范围

    /// 当前光标 / 选区能执行的语句（`docs/tech-designs/10-query-editor.md` §5.1）。
    func statements(for scope: SQLExecutionScope) -> [SQLStatement] {
        let nsText = text as NSString
        if scope == .currentStatement, selectedRange.length > 0 {
            let selection = nsText.substring(with: selectedRange)
            return StatementSplitter.split(selection)
        }
        let all = StatementSplitter.split(text)
        guard scope == .currentStatement else { return all }
        let cursor = min(max(selectedRange.location, 0), nsText.length)
        if let match = all.first(where: {
            cursor >= $0.range.location && cursor < $0.range.endLocation
        }) {
            return [match]
        }
        // 光标停在语句末尾（`;` 之后）或空行时，取光标前最近的一条。
        if let previous = all.last(where: { $0.range.endLocation <= cursor }) {
            return [previous]
        }
        return all.first.map { [$0] } ?? []
    }

    /// 主执行按钮的默认范围（可在偏好改成「执行全部」）。
    var defaultScope: SQLExecutionScope { preferences.defaultExecutionScope }

    func executeDefault() {
        run(statements(for: defaultScope))
    }

    func executeCurrentStatement() {
        run(statements(for: .currentStatement))
    }

    func executeAll() {
        run(statements(for: .allStatements))
    }

    /// 直接执行一段 SQL（历史「重新执行」等场景）。
    func executeSQL(_ sql: String) {
        run(StatementSplitter.split(sql))
    }

    // MARK: 执行

    /// 逐条下发（`docs/tech-designs/10-query-editor.md` §5.2）。
    private func run(_ statements: [SQLStatement]) {
        guard !isRunning else { return }
        guard !statements.isEmpty else {
            showNotice("没有可执行的语句")
            return
        }
        guard session.state.isConnected else {
            showNotice("连接不可用，请先重新连接")
            return
        }

        results.removeAll()
        selectedResultID = nil
        executedStatementCount = 0
        totalReturnedRows = 0
        receivedRowCount = 0
        receivedByteCount = 0
        showsLargeResultHint = false
        isRunning = true
        isStopping = false
        elapsedMilliseconds = 0
        startedAt = clock.now
        startElapsedTimer()

        let stopOnError = preferences.stopOnError
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var blockedCount = 0
            for (index, statement) in statements.enumerated() {
                if Task.isCancelled { break }
                if self.session.isReadOnly, !SQLStatementClassifier.isReadOnlyAllowed(statement.text) {
                    let blocked = QueryResultTab(ordinal: index + 1, statement: statement)
                    blocked.markBlocked(reason: QueryResultTab.readOnlyBlockedMessage)
                    self.append(blocked)
                    blockedCount += 1
                    continue
                }
                let started = self.clock.now
                do {
                    let result = try await self.session.execute(
                        statement.text,
                        database: self.session.selectedDatabase
                    )
                    let duration = Self.milliseconds(from: started, to: self.clock.now)
                    let resultTab = QueryResultTab(ordinal: index + 1, statement: statement)
                    resultTab.apply(result: result, durationMilliseconds: duration)
                    self.append(resultTab)
                    self.executedStatementCount += 1
                    self.totalReturnedRows += result.rowCount
                    self.receivedRowCount += result.rowCount
                    self.receivedByteCount += resultTab.byteCount
                    if resultTab.isLarge { self.showsLargeResultHint = true }
                    if result.wasCancelled { break }
                    if result.hasErrors, stopOnError { break }
                } catch {
                    let duration = Self.milliseconds(from: started, to: self.clock.now)
                    let resultTab = QueryResultTab(ordinal: index + 1, statement: statement)
                    let mysqlError = (error as? MySQLError) ?? MySQLError(
                        kind: .server,
                        code: 0,
                        sqlState: "",
                        message: String(describing: error)
                    )
                    resultTab.markFailure(mysqlError, durationMilliseconds: duration)
                    self.append(resultTab)
                    self.executedStatementCount += 1
                    if mysqlError.isCancellation {
                        self.showNotice("查询已取消")
                        break
                    }
                    if stopOnError { break }
                }
            }
            self.finishRun(blockedCount: blockedCount)
        }
    }

    /// 停止（`⌘.`）：取消 Task + 向服务器发 `KILL QUERY`（01 §3.1）。
    ///
    /// 取消失败（如权限不足）时提示 `取消失败，查询仍在服务器上运行`（`specs/06-query-editor.md` §9）。
    func stop() {
        guard isRunning else { return }
        isStopping = true
        runTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.session.cancelCurrentQuery()
            } catch {
                self.showNotice("取消失败，查询仍在服务器上运行")
            }
        }
    }

    /// 等待本次执行结束（单测 / 冒烟用）。
    func waitForExecution() async {
        let task = runTask
        await task?.value
    }

    private func finishRun(blockedCount: Int) {
        isRunning = false
        isStopping = false
        elapsedTask?.cancel()
        elapsedTask = nil
        if let startedAt {
            elapsedMilliseconds = Self.milliseconds(from: startedAt, to: clock.now)
        }
        runTask = nil
        if blockedCount > 0 {
            showNotice("只读模式：已跳过 \(blockedCount) 条写操作语句")
        }
        if let last = results.last, last.kind == .failure, last.error?.isCancellation == true {
            // 取消提示已在循环里给过
        }
    }

    private func append(_ result: QueryResultTab) {
        results.append(result)
        if selectedResultID == nil || result.kind == .failure {
            selectedResultID = result.id
        }
    }

    // MARK: 结果标签操作

    var selectedResult: QueryResultTab? {
        guard let selectedResultID else { return results.first }
        return results.first { $0.id == selectedResultID } ?? results.first
    }

    /// 结果集标签数量（状态栏「共 N 条」）。
    var resultSetCount: Int {
        results.filter { $0.kind == .resultSet }.count
    }

    func selectResult(_ id: UUID) {
        selectedResultID = id
    }

    func closeResult(_ id: UUID) {
        results.removeAll { $0.id == id }
        if selectedResultID == id {
            selectedResultID = results.first?.id
        }
    }

    func closeOtherResults(keeping id: UUID) {
        results.removeAll { $0.id != id }
        selectedResultID = id
    }

    func closeAllResults() {
        results.removeAll()
        selectedResultID = nil
    }

    func copyStatement(_ result: QueryResultTab) {
        copyToPasteboard(result.statementText)
    }

    func copyResult(_ result: QueryResultTab) {
        guard !result.rows.isEmpty else { return }
        let text = CopyFormatter.format(rows: result.rows, columns: result.columns, format: .csvWithHeader)
        copyToPasteboard(text)
    }

    // MARK: 历史回填

    /// 把历史里的 SQL 插入/回填到当前查询标签。
    ///
    /// `append` 为 true 时追加到末尾（双击历史），否则整体替换（「在新标签打开」走新标签）。
    func insertHistorySQL(_ sql: String, append: Bool) {
        if append, !text.isEmpty {
            text += text.hasSuffix("\n") ? "" : "\n"
            text += sql
        } else {
            text = sql
        }
        isDirty = true
        scheduleDraftSave()
    }

    // MARK: 草稿

    private func scheduleDraftSave() {
        guard preferences.autoSaveDraft, let draftID = tab.kind.draftID else { return }
        draftTask?.cancel()
        let content = text
        let store = drafts
        draftTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? await store.write(content, id: draftID)
        }
    }

    /// 立即落盘一次草稿（关闭标签 / 退出前）。
    func flushDraft() {
        guard let draftID = tab.kind.draftID else { return }
        let content = text
        let store = drafts
        Task { try? await store.write(content, id: draftID) }
    }

    // MARK: 脚本文件

    var hasFile: Bool { filePath != nil }

    var hasUnsavedFileChanges: Bool { filePath != nil && isDirty }

    /// `⌘S`：有关联文件直接保存，否则另存为。
    @discardableResult
    func saveScript() -> Bool {
        if filePath != nil {
            return saveToDisk()
        }
        return saveScriptAs()
    }

    /// `⇧⌘S`：另存为。
    @discardableResult
    func saveScriptAs() -> Bool {
        let defaultName = filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "\(tab.title).sql"
        guard let url = ScriptFileController.saveAsPanel(defaultName: defaultName, contents: text) else {
            return false
        }
        filePath = url.path
        tab.filePath = url.path
        tab.customTitle = url.lastPathComponent
        isDirty = false
        return true
    }

    private func saveToDisk() -> Bool {
        guard let filePath else { return false }
        guard ScriptFileController.write(text, to: URL(fileURLWithPath: filePath)) else { return false }
        isDirty = false
        return true
    }

    /// 从磁盘打开脚本到**本**标签（用于已存在的标签复用）。
    func loadScript(url: URL) -> Bool {
        guard let contents = try? ScriptFileController.read(url) else { return false }
        text = contents
        filePath = url.path
        tab.filePath = url.path
        tab.customTitle = url.lastPathComponent
        isDirty = false
        return true
    }

    /// 关闭标签前的保存确认。返回 `false` 表示取消关闭。
    func resolveClosePrompt() async -> Bool {
        guard hasUnsavedFileChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "「\(tab.title)」有未保存的改动"
        alert.informativeText = "关闭前要保存到脚本文件吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveScript()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: 辅助

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        let start = clock.now
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.elapsedMilliseconds = Self.milliseconds(from: start, to: self.clock.now)
            }
        }
    }

    private func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
