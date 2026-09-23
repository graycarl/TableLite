import XCTest
@testable import TableLite

/// SQL 编辑器：语句定位、编辑命令、执行编排、只读拦截、历史与草稿。
@MainActor
final class QueryEditorTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    // MARK: 当前语句定位

    func testStatementRangeLocatorPicksContainingStatement() {
        let sql = "SELECT 1;\nSELECT 2;\nSELECT 3"
        let tokens = SQLLexer.tokenize(sql)
        let length = (sql as NSString).length

        let first = SQLStatementRangeLocator.statementRange(in: tokens, textLength: length, cursor: 3)
        XCTAssertEqual(first?.location, 0)
        XCTAssertEqual(first?.length, 9)

        let secondCursor = (sql as NSString).range(of: "SELECT 2").location + 2
        let second = SQLStatementRangeLocator.statementRange(in: tokens, textLength: length, cursor: secondCursor)
        XCTAssertEqual(second?.location, 10)

        // 光标落在语句末尾之后 → 下一条。
        let third = SQLStatementRangeLocator.statementRange(in: tokens, textLength: length, cursor: length)
        XCTAssertEqual(third?.location, 20)
    }

    func testStatementRangeLocatorSkipsSemicolonInsideString() {
        let sql = "SELECT ';' ; SELECT 2"
        let tokens = SQLLexer.tokenize(sql)
        let length = (sql as NSString).length
        let range = SQLStatementRangeLocator.statementRange(in: tokens, textLength: length, cursor: 3)
        XCTAssertEqual(range?.location, 0)
        XCTAssertEqual(range?.length, 12)
    }

    // MARK: 编辑命令

    func testToggleCommentAddsAndRemoves() {
        let text = "SELECT 1\nSELECT 2"
        let full = NSRange(location: 0, length: (text as NSString).length)
        let added = SQLTextEditing.toggleComment(text: text, selection: full, indentWidth: 4)
        XCTAssertEqual(added.text, "-- SELECT 1\n-- SELECT 2")

        let removed = SQLTextEditing.toggleComment(
            text: added.text,
            selection: NSRange(location: 0, length: (added.text as NSString).length),
            indentWidth: 4
        )
        XCTAssertEqual(removed.text, text)
    }

    func testToggleCommentRespectsIndent() {
        let text = "    SELECT 1"
        let result = SQLTextEditing.toggleComment(text: text, selection: NSRange(location: 5, length: 0), indentWidth: 4)
        XCTAssertEqual(result.text, "    -- SELECT 1")
    }

    func testIndentAndDedent() {
        let text = "SELECT 1\nSELECT 2"
        let full = NSRange(location: 0, length: (text as NSString).length)
        let indented = SQLTextEditing.indent(text: text, selection: full, indentWidth: 4)
        XCTAssertEqual(indented.text, "    SELECT 1\n    SELECT 2")
        let dedented = SQLTextEditing.dedent(
            text: indented.text,
            selection: NSRange(location: 0, length: (indented.text as NSString).length),
            indentWidth: 4
        )
        XCTAssertEqual(dedented.text, text)
    }

    // MARK: 结果标签

    func testResultTabAppliesResultSetAndAffected() {
        let statement = SQLStatement(text: "SELECT 1", range: TextRange(location: 0, length: 8), kind: .query)
        let tab = QueryResultTab(ordinal: 1, statement: statement)
        tab.apply(result: .single(columns: ["a"], rows: [["1"], ["2"]]), durationMilliseconds: 12)
        XCTAssertEqual(tab.kind, .resultSet)
        XCTAssertEqual(tab.title, "结果 1")
        XCTAssertEqual(tab.rows.count, 2)

        let dml = SQLStatement(text: "UPDATE t SET a=1", range: TextRange(location: 0, length: 15), kind: .dml)
        let affectedTab = QueryResultTab(ordinal: 2, statement: dml)
        let affected = MySQLQueryResult(
            resultSets: [],
            statementErrors: [],
            wasCancelled: false,
            rowCount: 0,
            affectedRows: 3,
            lastInsertID: 42
        )
        affectedTab.apply(result: affected, durationMilliseconds: 5)
        XCTAssertEqual(affectedTab.kind, .affected)
        XCTAssertEqual(affectedTab.title, "完成")
        XCTAssertTrue(affectedTab.affectedSummary.contains("影响 3 行"))
        XCTAssertTrue(affectedTab.affectedSummary.contains("last_insert_id = 42"))
    }

    // MARK: 执行编排

    func testExecuteAllProducesOneTabPerStatement() async throws {
        let session = try await connect()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses() + [
            ("SELECT 1", .single(columns: ["a"], rows: [["1"]])),
            ("SELECT 2", .single(columns: ["a"], rows: [["2"]])),
        ])
        let model = makeModel(session)
        model.textChanged("SELECT 1; SELECT 2;")
        model.executeAll()
        await model.waitForExecution()
        XCTAssertEqual(model.results.count, 2)
        XCTAssertTrue(model.results.allSatisfy { $0.kind == .resultSet })
        XCTAssertEqual(model.selectedResult?.ordinal, 1)
    }

    func testExecuteCurrentStatementOnlyRunsCursorStatement() async throws {
        let session = try await connect()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses() + [
            ("SELECT 1", .single(columns: ["a"], rows: [["1"]])),
            ("SELECT 2", .single(columns: ["a"], rows: [["2"]])),
        ])
        let model = makeModel(session)
        let sql = "SELECT 1;\nSELECT 2;"
        model.textChanged(sql)
        model.selectionChanged(NSRange(location: 12, length: 0))
        model.executeCurrentStatement()
        await model.waitForExecution()
        XCTAssertEqual(model.results.count, 1)
        XCTAssertTrue(model.results[0].statementText.contains("SELECT 2"))
    }

    func testExecuteDefaultHonorsPreferenceScope() async throws {
        let session = try await connect()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses() + [
            ("SELECT 1", .single(columns: ["a"], rows: [["1"]])),
            ("SELECT 2", .single(columns: ["a"], rows: [["2"]])),
        ])
        let sql = "SELECT 1;\nSELECT 2;"

        // 偏好改成「执行全部」时 `⌘↩`（executeDefault）跑整段脚本。
        harness.preferences.defaultExecutionScope = .allStatements
        let allModel = makeModel(session)
        allModel.textChanged(sql)
        allModel.selectionChanged(NSRange(location: 3, length: 0))
        allModel.executeDefault()
        await allModel.waitForExecution()
        XCTAssertEqual(allModel.results.count, 2)

        // 默认「执行当前语句」时只跑光标所在语句。
        harness.preferences.defaultExecutionScope = .currentStatement
        let currentModel = makeModel(session)
        currentModel.textChanged(sql)
        currentModel.selectionChanged(NSRange(location: 12, length: 0))
        currentModel.executeDefault()
        await currentModel.waitForExecution()
        XCTAssertEqual(currentModel.results.count, 1)
        XCTAssertTrue(currentModel.results[0].statementText.contains("SELECT 2"))
    }

    func testCancelFailureShowsNotice() async throws {
        let session = try await connect()
        await harness.mysql.setCancelError(
            MySQLError.server(code: 1095, sqlState: "HY000", message: "You are not owner of thread")
        )
        let model = makeModel(session)
        model.textChanged("SELECT SLEEP(10);")
        model.executeAll()
        XCTAssertTrue(model.isRunning)
        model.stop()
        await waitForNotice(model, equals: "取消失败，查询仍在服务器上运行")
    }

    func testResultTabComputesApproximateByteCount() {
        let statement = SQLStatement(text: "SELECT a", range: TextRange(location: 0, length: 8), kind: .query)
        let tab = QueryResultTab(ordinal: 1, statement: statement)
        tab.apply(result: .single(columns: ["a"], rows: [["hello"], ["world!"]]), durationMilliseconds: 1)
        XCTAssertEqual(tab.byteCount, "hello".utf8.count + "world!".utf8.count)
    }

    func testResultColumnVisibilityKeepsAtLeastOneColumn() {
        XCTAssertEqual(ResultColumnVisibility.toggling(index: 0, in: [], columnCount: 2), [0])
        XCTAssertEqual(ResultColumnVisibility.toggling(index: 1, in: [0], columnCount: 2), [0])
        XCTAssertEqual(ResultColumnVisibility.toggling(index: 0, in: [0], columnCount: 2), [])
        XCTAssertEqual(ResultColumnVisibility.toggling(index: 1, in: [0, 1], columnCount: 2), [0])
        XCTAssertEqual(ResultColumnVisibility.toggling(index: 0, in: [0, 1], columnCount: 2), [1])
        XCTAssertEqual(ResultColumnVisibility.toggling(index: 5, in: [], columnCount: 2), [])
        XCTAssertEqual(ResultColumnVisibility.toggling(index: 0, in: [], columnCount: 0), [])
    }

    func testSyntaxErrorProducesFailureTab() async throws {
        let session = try await connect()
        let syntaxError = MySQLError.server(code: 1064, sqlState: "42000", message: "You have an error in your SQL syntax")
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses() + [
            ("BAD", .statementError(syntaxError)),
        ])
        let model = makeModel(session)
        model.textChanged("BAD SQL")
        model.executeAll()
        await model.waitForExecution()
        XCTAssertEqual(model.results.first?.kind, .failure)
        XCTAssertEqual(model.results.first?.error?.code, 1064)
        XCTAssertEqual(model.results.first?.title, "错误")
    }

    func testStopOnErrorStopsLaterStatements() async throws {
        let session = try await connect()
        let syntaxError = MySQLError.server(code: 1064, sqlState: "42000", message: "syntax error")
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses() + [
            ("SELECT 1", .single(columns: ["a"], rows: [["1"]])),
            ("BAD", .statementError(syntaxError)),
        ])
        harness.preferences.stopOnError = true
        let model = makeModel(session)
        model.textChanged("SELECT 1; BAD; SELECT 3;")
        model.executeAll()
        await model.waitForExecution()
        // 第 3 条不应被下发。
        let executed = await harness.mysql.executedSQL
        XCTAssertFalse(executed.contains { $0.contains("SELECT 3") })
        XCTAssertEqual(model.results.count, 2)
    }

    func testReadOnlyBlocksWritesButRunsSafeStatements() async throws {
        let session = try await connect()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses() + [
            ("SELECT", .single(columns: ["a"], rows: [["1"]])),
        ])
        session.setReadOnly(true)
        let model = makeModel(session)
        model.textChanged("INSERT INTO t VALUES (1); SELECT 1;")
        model.executeAll()
        await model.waitForExecution()
        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.results[0].kind, .blocked)
        XCTAssertEqual(model.results[1].kind, .resultSet)

        let executed = await harness.mysql.executedSQL
        XCTAssertFalse(executed.contains { $0.hasPrefix("INSERT") })
        XCTAssertTrue(executed.contains { $0.contains("SELECT 1") })
        XCTAssertEqual(model.notice, "只读模式：已跳过 1 条写操作语句")
        XCTAssertEqual(model.results[0].blockedReason, QueryResultTab.readOnlyBlockedMessage)
        XCTAssertEqual(
            QueryResultTab.readOnlyBlockedMessage,
            "当前连接处于只读模式，只能执行查询语句。如需修改，请在连接菜单中关闭只读模式。"
        )
    }

    func testReadOnlyBlocksCTEWrite() async throws {
        let session = try await connect()
        session.setReadOnly(true)
        let model = makeModel(session)
        model.textChanged("WITH c AS (SELECT 1) INSERT INTO t SELECT * FROM c;")
        model.executeAll()
        await model.waitForExecution()
        XCTAssertEqual(model.results.first?.kind, .blocked)
    }

    // MARK: USE 拦截

    func testUseStatementIsBlockedAndNotSent() async throws {
        let session = try await connect()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses() + [
            ("SELECT 1", .single(columns: ["a"], rows: [["1"]])),
        ])
        let model = makeModel(session)
        model.textChanged("USE other; SELECT 1;")
        model.executeAll()
        await model.waitForExecution()

        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.results[0].kind, .blocked)
        XCTAssertEqual(model.results[0].title, QueryResultTab.useBlockedLabel)
        XCTAssertEqual(model.results[0].blockedReason, QueryResultTab.useBlockedMessage)
        XCTAssertEqual(model.results[1].kind, .resultSet)

        // `USE` 不下发服务器；其余语句照常执行。
        let executed = await harness.mysql.executedSQL
        XCTAssertFalse(executed.contains { $0.uppercased().hasPrefix("USE ") })
        XCTAssertTrue(executed.contains { $0.contains("SELECT 1") })
        XCTAssertEqual(model.notice, QueryResultTab.useBlockedMessage)
    }

    func testUseStatementIsBlockedEvenInReadOnlyMode() async throws {
        let session = try await connect()
        session.setReadOnly(true)
        let model = makeModel(session)
        model.textChanged("USE other;")
        model.executeAll()
        await model.waitForExecution()

        // 只读与否一致：提示「请通过侧栏切换数据库」，而不是只读拦截文案。
        XCTAssertEqual(model.results.first?.kind, .blocked)
        XCTAssertEqual(model.results.first?.blockedReason, QueryResultTab.useBlockedMessage)
        XCTAssertEqual(model.notice, QueryResultTab.useBlockedMessage)
    }

    // MARK: 历史与草稿

    func testExecuteWritesHistoryAndConsoleLog() async throws {
        let session = try await connect()
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses() + [
            ("SELECT 42", .single(columns: ["a"], rows: [["42"]])),
        ])
        let model = makeModel(session)
        model.textChanged("SELECT 42;")
        model.executeAll()
        await model.waitForExecution()

        let count = try await harness.history.count(connectionID: session.id)
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertTrue(harness.consoleLog.allEntries.contains { $0.sql == "SELECT 42;" && $0.tag == .data })
    }

    func testFlushDraftWritesContent() async throws {
        let session = try await connect()
        let model = makeModel(session)
        model.textChanged("SELECT draft;")
        model.flushDraft()

        let draftID = try XCTUnwrap(model.tab.kind.draftID)
        let content = await waitForDraft(draftID: draftID)
        XCTAssertEqual(content, "SELECT draft;")
    }

    func testHistoryInsertAppendsToCurrentText() async throws {
        let session = try await connect()
        let model = makeModel(session)
        model.textChanged("SELECT 1;")
        model.insertHistorySQL("SELECT 2;", append: true)
        XCTAssertEqual(model.text, "SELECT 1;\nSELECT 2;")
        model.insertHistorySQL("SELECT 3;", append: false)
        XCTAssertEqual(model.text, "SELECT 3;")
    }

    // MARK: 工具

    private func connect() async throws -> ConnectionSession {
        let connection = SessionTestSupport.connection()
        return try await harness.manager.connect(connection, password: nil)
    }

    private func makeModel(_ session: ConnectionSession) -> QueryEditorViewModel {
        let tab = session.newQueryTab()
        return QueryEditorViewModel(
            session: session,
            tab: tab,
            preferences: harness.preferences,
            drafts: harness.drafts,
            clock: harness.clock
        )
    }

    private func waitForDraft(draftID: UUID, timeout: TimeInterval = 2) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = try? await harness.drafts.read(id: draftID) {
                return content
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func waitForNotice(
        _ model: QueryEditorViewModel,
        equals expected: String,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.notice == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("未等到提示「\(expected)」，当前为 \(model.notice ?? "nil")")
    }
}
