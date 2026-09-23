import XCTest
@testable import TableLite

/// W3-T9 编辑与提交：字段栏进暂存 / 合并 / 校验、提交事务路径、预览与提交一致、
/// 大字段截断保护（L27 / 08 §9）、可编辑性判定、重载保留暂存。
///
/// 见 `specs/04-data-editing.md`、`docs/tech-designs/08-pending-changes.md`、`14-row-inspector.md`。
@MainActor
final class TableDataEditingTests: XCTestCase {

    private var harness: SessionTestHarness!

    override func setUp() async throws {
        harness = SessionTestSupport.makeHarness()
        harness.preferences.lazyLargeColumns = false
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
    }

    override func tearDown() async throws {
        harness?.clean()
        harness = nil
    }

    // MARK: 装配

    private static let columns: [ColumnInfo] = [
        TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63),
        TestSupport.column("name", type: .varString),
        TestSupport.column("email", type: .varString),
    ]

    private func makeSession() async throws -> ConnectionSession {
        try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
    }

    private func makeViewModel(
        session: ConnectionSession,
        columns: [ColumnInfo] = TableDataEditingTests.columns,
        primaryKeyColumns: [String] = ["id"]
    ) -> (TableDataViewModel, Tab) {
        let tab = session.openTableData(database: "app_dev", table: "users")
        let metadata = TableDataMetadata(
            columns: columns,
            tableInfo: TableInfo(database: "app_dev", name: "users", rowCountEstimate: 2),
            isView: false,
            primaryKeyColumns: primaryKeyColumns
        )
        let provider = FakeTableDataMetadataProvider(metadata: metadata, rowCount: RowCountEstimate(approximate: 2))
        let viewModel = TableDataViewModel(
            session: session,
            tab: tab,
            metadataProvider: provider,
            preferences: harness.preferences,
            clock: harness.clock
        )
        return (viewModel, tab)
    }

    private func pageResponse(_ rows: [[String?]]) -> (String, MySQLQueryResult) {
        ("FROM `app_dev`.`users`", .single(columns: ["id", "name", "email"], rows: rows))
    }

    private func twoRowsResponse() -> (String, MySQLQueryResult) {
        pageResponse([["1", "张三", "a@b.c"], ["2", "李四", "d@e.f"]])
    }

    private func executedSuffix(from count: Int) async -> [String] {
        let executed = await harness.mysql.executedSQL
        return Array(executed.dropFirst(count))
    }

    // MARK: 进暂存 / 合并

    func testInspectorEditEntersStoreAndMergesSameRow() async throws {
        let session = try await makeSession()
        let (viewModel, tab) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        let rowID = viewModel.rows[0].id
        await viewModel.applyInspectorEdit(rowID: rowID, column: "name", value: .text("新名"))
        XCTAssertEqual(viewModel.pendingCount, 1)
        XCTAssertEqual(viewModel.rows[0].changeKind, .update)
        XCTAssertEqual(viewModel.rows[0].cells["name"]?.draftValue, .text("新名"))
        XCTAssertTrue(tab.hasPendingChanges)

        // 再改同一行其它列 → 合并为一条修改。
        await viewModel.applyInspectorEdit(rowID: rowID, column: "email", value: .text("new@b.c"))
        XCTAssertEqual(viewModel.pendingStore.counts.update, 1)
        XCTAssertEqual(viewModel.pendingStore.changes.first?.edits.count, 2)
    }

    func testRevertingToOriginalRemovesChange() async throws {
        let session = try await makeSession()
        let (viewModel, tab) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        let rowID = viewModel.rows[0].id
        await viewModel.applyInspectorEdit(rowID: rowID, column: "name", value: .text("新名"))
        await viewModel.applyInspectorEdit(rowID: rowID, column: "name", value: .text("张三"))
        XCTAssertEqual(viewModel.pendingCount, 0)
        XCTAssertFalse(tab.hasPendingChanges)
        XCTAssertNil(viewModel.rows[0].changeKind)
    }

    func testInsertThenEditAndDeleteCancel() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        viewModel.beginInsert()
        let insertionID = viewModel.insertionRows[0].id
        XCTAssertEqual(viewModel.rows[0].changeKind, nil)
        await viewModel.applyInspectorEdit(rowID: insertionID, column: "name", value: .text("新增"))
        XCTAssertEqual(viewModel.pendingStore.counts.insert, 1)
        XCTAssertEqual(viewModel.insertionRows[0].cells["name"]?.draftValue, .text("新增"))

        // 新增行又删除：两者都消失，不产生 SQL，且不弹确认（没有 WHERE 条件）。
        viewModel.deleteRows(rowIDs: [insertionID])
        XCTAssertNil(viewModel.pendingDeletion)
        XCTAssertEqual(viewModel.pendingCount, 0)
        XCTAssertTrue(viewModel.insertionRows.isEmpty)
    }

    func testDeleteExistingRowReplacesUpdate() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        let rowID = viewModel.rows[0].id
        await viewModel.applyInspectorEdit(rowID: rowID, column: "name", value: .text("新名"))
        viewModel.deleteRows(rowIDs: [rowID])
        // 删除已有行先展示 WHERE 条件等用户确认（`specs/04-data-editing.md` §6）。
        XCTAssertNotNil(viewModel.pendingDeletion)
        XCTAssertEqual(viewModel.pendingStore.changes.count, 1)
        viewModel.confirmDeletion()
        XCTAssertNil(viewModel.pendingDeletion)
        XCTAssertEqual(viewModel.pendingStore.changes.first?.kind, .delete)
        XCTAssertEqual(viewModel.rows[0].changeKind, .deletion)
    }

    func testDeleteExistingRowShowsConditionBeforeConfirm() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        viewModel.deleteRows(rowIDs: [viewModel.rows[0].id])
        let pending = try XCTUnwrap(viewModel.pendingDeletion)
        XCTAssertEqual(pending.conditions.count, 1)
        XCTAssertTrue(pending.conditions[0].hasPrefix("WHERE `id` = "))
        XCTAssertTrue(pending.conditions[0].hasSuffix("1"))
        // 确认前不动暂存区。
        XCTAssertTrue(viewModel.pendingStore.isEmpty)

        viewModel.cancelDeletion()
        XCTAssertNil(viewModel.pendingDeletion)
        XCTAssertTrue(viewModel.pendingStore.isEmpty)
        XCTAssertNil(viewModel.rows[0].changeKind)
    }

    func testUndoRowOnlyRevertsOneRow() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("A"))
        await viewModel.applyInspectorEdit(rowID: viewModel.rows[1].id, column: "name", value: .text("B"))
        viewModel.undoRow(rowID: viewModel.rows[0].id)
        XCTAssertEqual(viewModel.pendingCount, 1)
        XCTAssertNil(viewModel.rows[0].changeKind)
        XCTAssertEqual(viewModel.rows[1].changeKind, .update)
    }

    // MARK: 提交事务

    func testSubmitRunsSingleTransactionThenClearsStore() async throws {
        let session = try await makeSession()
        let (viewModel, tab) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("新名"))
        viewModel.beginInsert()
        await viewModel.applyInspectorEdit(rowID: viewModel.insertionRows[0].id, column: "name", value: .text("新增"))
        viewModel.deleteRows(rowIDs: [viewModel.rows[1].id])
        viewModel.confirmDeletion()
        XCTAssertEqual(viewModel.pendingCount, 3)

        let before = await harness.mysql.executedSQL.count
        let succeeded = await viewModel.submitChanges()
        XCTAssertTrue(succeeded)

        let suffix = await executedSuffix(from: before)
        let dml = suffix.filter { !$0.hasPrefix("SELECT") }
        XCTAssertEqual(dml.first, "BEGIN")
        XCTAssertEqual(dml.last, "COMMIT")
        XCTAssertEqual(dml.filter { $0 == "BEGIN" }.count, 1)
        XCTAssertEqual(dml.filter { $0 == "COMMIT" }.count, 1)
        let insertIndex = try XCTUnwrap(dml.firstIndex { $0.hasPrefix("INSERT INTO") })
        let updateIndex = try XCTUnwrap(dml.firstIndex { $0.hasPrefix("UPDATE") })
        let deleteIndex = try XCTUnwrap(dml.firstIndex { $0.hasPrefix("DELETE") })
        XCTAssertLessThan(insertIndex, updateIndex)
        XCTAssertLessThan(updateIndex, deleteIndex)

        XCTAssertTrue(viewModel.pendingStore.isEmpty)
        XCTAssertFalse(tab.hasPendingChanges)
        XCTAssertTrue(viewModel.insertionRows.isEmpty)
    }

    func testSubmitRollsBackOnStatementErrorInResult() async throws {
        // `ConnectionSession.execute` 对语句级错误不抛异常，而是放在 `result.firstError` 里；
        // 提交路径必须显式检查，否则唯一键冲突会被当作成功。
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()
        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("改"))

        let error = MySQLError.server(code: 1062, sqlState: "23000", message: "Duplicate entry")
        await harness.mysql.setResponses([
            ("FROM `app_dev`.`users`", twoRowsResponse().1),
            ("UPDATE", .statementError(error)),
        ])
        let before = await harness.mysql.executedSQL.count
        let succeeded = await viewModel.submitChanges()
        XCTAssertFalse(succeeded)
        let suffix = await executedSuffix(from: before)
        XCTAssertTrue(suffix.contains("ROLLBACK"))
        XCTAssertFalse(suffix.contains("COMMIT"))
        XCTAssertEqual(viewModel.pendingCount, 1)
        XCTAssertEqual(viewModel.commitFailure?.code, 1062)
    }

    func testSubmitFailureRollsBackAndKeepsStore() async throws {
        let session = try await makeSession()
        let (viewModel, tab) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("改"))
        viewModel.deleteRows(rowIDs: [viewModel.rows[1].id])
        viewModel.confirmDeletion()
        await harness.mysql.setFailures([
            ("UPDATE", MySQLError.server(code: 1062, sqlState: "23000", message: "Duplicate entry 'x' for key 'uniq'")),
        ])

        let before = await harness.mysql.executedSQL.count
        let succeeded = await viewModel.submitChanges()
        XCTAssertFalse(succeeded)

        let suffix = await executedSuffix(from: before)
        XCTAssertEqual(suffix.first, "BEGIN")
        XCTAssertTrue(suffix.contains("ROLLBACK"))
        XCTAssertFalse(suffix.contains("COMMIT"))
        XCTAssertEqual(viewModel.pendingCount, 2)
        XCTAssertTrue(tab.hasPendingChanges)

        let failure = try XCTUnwrap(viewModel.commitFailure)
        XCTAssertEqual(failure.code, 1062)
        XCTAssertEqual(failure.sqlState, "23000")
        XCTAssertEqual(failure.index, 1)
        XCTAssertTrue(failure.impactText.contains("事务已回滚"))
    }

    func testSubmitEmptyStoreIsNoOp() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        let before = await harness.mysql.executedSQL.count
        let succeeded = await viewModel.submitChanges()
        XCTAssertTrue(succeeded)
        let suffix = await executedSuffix(from: before)
        XCTAssertFalse(suffix.contains("BEGIN"))
    }

    func testCancelCommitOutsideCommitIsIgnored() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()
        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("改"))
        viewModel.cancelCommit() // 未在提交中：忽略
        let succeeded = await viewModel.submitChanges()
        XCTAssertTrue(succeeded)
    }

    // MARK: 预览与提交一致

    func testPreviewStatementsMatchCommit() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("张三'引号\\反斜杠"))
        viewModel.beginInsert()
        await viewModel.applyInspectorEdit(rowID: viewModel.insertionRows[0].id, column: "name", value: .text("新增"))

        viewModel.presentPreview()
        XCTAssertTrue(viewModel.isPreviewPresented)
        let preview = viewModel.previewStatements
        XCTAssertEqual(preview.count, 2)

        let before = await harness.mysql.executedSQL.count
        _ = await viewModel.submitChanges()
        let suffix = await executedSuffix(from: before)
        let dml = suffix.filter { $0.hasPrefix("INSERT") || $0.hasPrefix("UPDATE") || $0.hasPrefix("DELETE") }
        XCTAssertEqual(dml, preview, "预览与实际提交必须逐字节一致（S29）")
    }

    // MARK: 大字段截断保护

    private func truncatedContentSetup() async throws -> (TableDataViewModel, ConnectionSession, String) {
        harness.preferences.lazyLargeColumns = true
        harness.preferences.lazyLargeColumnThreshold = 256
        let session = try await makeSession()
        let contentColumn = TestSupport.column(
            "content",
            type: .blob,
            charset: 33,
            dataType: "text",
            columnType: "longtext"
        )
        let columns = [Self.columns[0], Self.columns[1], contentColumn]
        let (viewModel, _) = makeViewModel(session: session, columns: columns)
        let prefix = String(repeating: "a", count: 300)
        let page = MySQLQueryResult.single(
            columns: ["id", "name", "content", "__mtl_len_2"],
            rows: [["1", "张三", prefix, "10000"]]
        )
        let full = MySQLQueryResult.single(
            columns: ["id", "name", "content"],
            rows: [["1", "张三", prefix + "FULL"]]
        )
        await harness.mysql.setResponses([("WHERE `id` =", full), ("FROM `app_dev`.`users`", page)])
        await viewModel.start()
        return (viewModel, session, prefix)
    }

    func testEditingAnotherColumnNeverWritesTruncatedValue() async throws {
        let (viewModel, _, _) = try await truncatedContentSetup()
        let rowID = viewModel.rows[0].id
        XCTAssertTrue(viewModel.rows[0].cells["content"]?.needsFullValueLoad ?? false)

        await viewModel.applyInspectorEdit(rowID: rowID, column: "name", value: .text("新名"))
        let statements = try viewModel.makeStatements()
        XCTAssertEqual(statements.count, 1)
        XCTAssertFalse(statements[0].contains("content"), "未编辑的截断列绝不能进入 SET（08 §9）")
        XCTAssertTrue(statements[0].contains("`name` = '新名'"))
    }

    func testEditingTruncatedColumnLoadsFullValueFirst() async throws {
        let (viewModel, _, prefix) = try await truncatedContentSetup()
        let rowID = viewModel.rows[0].id
        await viewModel.applyInspectorEdit(rowID: rowID, column: "content", value: .text("新内容"))
        let statements = try viewModel.makeStatements()
        XCTAssertTrue(statements[0].contains("`content` = '新内容'"))
        // 编辑前先二次加载了完整值。
        let executed = await harness.mysql.executedSQL
        XCTAssertTrue(executed.contains { $0.contains("WHERE `id` =") })
        // 完整值已回填到单元格。
        XCTAssertEqual(viewModel.rows[0].cells["content"]?.fullValue, .text(prefix + "FULL"))
    }

    func testCopyRowsLoadsTruncatedAndClearsAutoIncrement() async throws {
        harness.preferences.lazyLargeColumns = true
        harness.preferences.lazyLargeColumnThreshold = 256
        let session = try await makeSession()
        let idColumn = TestSupport.column(
            "id",
            type: .long,
            flags: ColumnFlag.primaryKey | ColumnFlag.autoIncrement,
            charset: 63
        )
        let contentColumn = TestSupport.column(
            "content",
            type: .blob,
            charset: 33,
            dataType: "text",
            columnType: "longtext"
        )
        let columns = [idColumn, Self.columns[1], contentColumn]
        let (viewModel, _) = makeViewModel(session: session, columns: columns)
        let prefix = String(repeating: "a", count: 300)
        await harness.mysql.setResponses([
            ("WHERE `id` =", .single(columns: ["id", "name", "content"], rows: [["1", "张三", prefix + "FULL"]])),
            ("FROM `app_dev`.`users`", .single(
                columns: ["id", "name", "content", "__mtl_len_2"],
                rows: [["1", "张三", prefix, "10000"]]
            )),
        ])
        await viewModel.start()

        await viewModel.copySelectedRows(rowIDs: [viewModel.rows[0].id])
        XCTAssertEqual(viewModel.insertionRows.count, 1)
        let statements = try viewModel.makeStatements()
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].hasPrefix("INSERT INTO"))
        XCTAssertFalse(statements[0].contains("`id`"), "自增主键列复制时留空")
        XCTAssertTrue(statements[0].contains("`name`"))
        XCTAssertTrue(statements[0].contains("FULL"), "复制前必须加载完整大字段，不能写入截断值")
    }

    func testSQLInsertCopyWarnsWhenLargeFieldNotLoaded() async throws {
        let (viewModel, _, _) = try await truncatedContentSetup()
        let rowID = viewModel.rows[0].id
        // 关掉字段栏自动加载，确保复制时大字段仍未加载完整（复现 L27 场景）。
        harness.preferences.showInspector = false
        viewModel.updateSelection(rowIDs: [rowID], focusedRowID: rowID, focusedColumn: "name")
        let result = viewModel.makeCopy(format: .sqlInsert)
        let notice = try XCTUnwrap(result.notice)
        XCTAssertTrue(notice.contains("未加载"), "L27：SQL INSERT 复制遇未加载大字段必须给警告")
        XCTAssertTrue(result.text.contains("INSERT INTO"))
    }

    // MARK: 重载 / 放弃

    func testPendingChangesSurviveReload() async throws {
        let session = try await makeSession()
        let (viewModel, tab) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("新名"))
        viewModel.beginInsert()
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.reloadCurrentPage()

        XCTAssertEqual(viewModel.pendingCount, 2)
        XCTAssertTrue(tab.hasPendingChanges)
        XCTAssertEqual(viewModel.rows[0].changeKind, .update)
        XCTAssertEqual(viewModel.rows[0].cells["name"]?.draftValue, .text("新名"))
        XCTAssertEqual(viewModel.insertionRows.count, 1)
    }

    func testDiscardClearsStoreAndReloads() async throws {
        let session = try await makeSession()
        let (viewModel, tab) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("新名"))
        viewModel.beginInsert()
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.discardChanges()

        XCTAssertTrue(viewModel.pendingStore.isEmpty)
        XCTAssertFalse(tab.hasPendingChanges)
        XCTAssertTrue(viewModel.insertionRows.isEmpty)
        XCTAssertNil(viewModel.rows[0].changeKind)
    }

    func testDiscardConfirmationRule() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("A"))
        XCTAssertFalse(viewModel.needsDiscardConfirmation, "单条修改不打断")
        viewModel.beginInsert()
        XCTAssertTrue(viewModel.needsDiscardConfirmation, "含新增时先确认")
    }

    // MARK: 可编辑性判定

    func testNoPrimaryKeyIsReadOnly() async throws {
        let session = try await makeSession()
        let (viewModel, _) = makeViewModel(
            session: session,
            primaryKeyColumns: []
        )
        await harness.mysql.setResponses([pageResponse([["张三", "a@b.c", "1"]])])
        await viewModel.start()

        XCTAssertFalse(viewModel.isEditable)
        XCTAssertFalse(viewModel.isEditingEnabled)
        XCTAssertEqual(viewModel.editability.reason, .noPrimaryKey)
        XCTAssertEqual(viewModel.uneditableStatusText, "该表没有主键，行顺序不保证，且不可编辑")
    }

    func testReadOnlyConnectionIsReadOnly() async throws {
        let connection = SessionTestSupport.connection()
        let session = try await harness.manager.connect(connection, password: nil)
        session.setReadOnly(true)
        let (viewModel, _) = makeViewModel(session: session)
        await harness.mysql.setResponses([twoRowsResponse()])
        await viewModel.start()

        XCTAssertFalse(viewModel.isEditable)
        XCTAssertEqual(viewModel.editability.reason, .readOnlyConnection)

        // 只读连接下提交被拒且不产生 SQL。
        await viewModel.applyInspectorEdit(rowID: viewModel.rows[0].id, column: "name", value: .text("x"))
        XCTAssertEqual(viewModel.pendingCount, 0)
    }

    // MARK: 纯逻辑：编辑器选择与校验

    func testEditorKindResolution() {
        XCTAssertEqual(
            FieldEditorResolver.kind(for: TestSupport.column("id", type: .long, charset: 63), tinyintAsCheckbox: false),
            .number
        )
        XCTAssertEqual(
            FieldEditorResolver.kind(
                for: TestSupport.column("flag", type: .tiny, length: 1, columnType: "tinyint(1)"),
                tinyintAsCheckbox: true
            ),
            .booleanTinyInt
        )
        XCTAssertEqual(
            FieldEditorResolver.kind(for: TestSupport.column("d", type: .datetime), tinyintAsCheckbox: false),
            .temporal
        )
        XCTAssertEqual(
            FieldEditorResolver.kind(
                for: TestSupport.column("status", type: .enumeration, columnType: "enum('a','b')"),
                tinyintAsCheckbox: false
            ),
            .enumeration(["a", "b"])
        )
        XCTAssertEqual(
            FieldEditorResolver.kind(
                for: TestSupport.column("tags", type: .set, columnType: "set('x','y')"),
                tinyintAsCheckbox: false
            ),
            .set(["x", "y"])
        )
        XCTAssertEqual(
            FieldEditorResolver.kind(
                for: TestSupport.column("content", type: .blob, charset: 33, dataType: "text", columnType: "longtext"),
                tinyintAsCheckbox: false
            ),
            .multilineText
        )
        XCTAssertEqual(
            FieldEditorResolver.kind(
                for: TestSupport.column("payload", type: .blob, charset: 63),
                tinyintAsCheckbox: false
            ),
            .binary
        )
    }

    func testFieldEditValidationRules() {
        let number = TestSupport.column("age", type: .long, charset: 63)
        XCTAssertEqual(FieldEditValidator.validate(text: "abc", column: number, kind: .number), .notANumber)
        XCTAssertEqual(FieldEditValidator.validate(text: "1e5", column: number, kind: .number), .notANumber)
        XCTAssertNil(FieldEditValidator.validate(text: "-12.5", column: number, kind: .number))
        XCTAssertNil(FieldEditValidator.validate(text: "", column: number, kind: .number))

        let date = TestSupport.column("d", type: .date)
        XCTAssertNil(FieldEditValidator.validate(text: "2025-01-01", column: date, kind: .temporal))
        XCTAssertEqual(FieldEditValidator.validate(text: "2025-1-1", column: date, kind: .temporal), .invalidDate)

        let enumColumn = TestSupport.column("status", type: .enumeration, columnType: "enum('a','b')")
        XCTAssertNil(FieldEditValidator.validate(text: "a", column: enumColumn, kind: .enumeration(["a", "b"])))
        XCTAssertEqual(
            FieldEditValidator.validate(text: "c", column: enumColumn, kind: .enumeration(["a", "b"])),
            .valueNotInEnum
        )

        let setColumn = TestSupport.column("tags", type: .set, columnType: "set('x','y')")
        XCTAssertNil(FieldEditValidator.validate(text: "x,y", column: setColumn, kind: .set(["x", "y"])))
        XCTAssertEqual(
            FieldEditValidator.validate(text: "x,z", column: setColumn, kind: .set(["x", "y"])),
            .valueNotInSet("z")
        )
    }

    func testValueAndTextRoundTrip() {
        let number = TestSupport.column("age", type: .long, charset: 63)
        XCTAssertEqual(FieldEditValidator.value(fromText: "42", column: number, kind: .number), .text("42"))
        XCTAssertEqual(FieldEditValidator.text(from: .integer(7)), "7")
        XCTAssertEqual(FieldEditValidator.text(from: .bool(true)), "1")
        XCTAssertEqual(FieldEditValidator.text(from: .null), "")
    }
}
