import XCTest
@testable import TableLite

// MARK: - 测试夹具

/// 两个测试文件共用的纯逻辑夹具。见 docs/tech-designs/08-pending-changes.md。
enum PendingTestFixtures {

    static let table = TableRef(database: "app_dev", table: "users")

    static func column(
        _ name: String,
        _ dataType: String,
        rawType: String? = nil,
        pk: Bool = false,
        nullable: Bool = true
    ) -> TableColumn {
        TableColumn(
            name: name,
            dataType: dataType,
            rawTypeText: rawType ?? dataType,
            isNullable: nullable,
            isPrimaryKey: pk
        )
    }

    static func structure(
        _ columns: [TableColumn],
        kind: DatabaseObjectKind = .table,
        ref: TableRef = PendingTestFixtures.table
    ) -> TableStructure {
        TableStructure(
            ref: ref,
            kind: kind,
            comment: nil,
            columns: columns,
            indexes: [],
            foreignKeys: [],
            triggers: [],
            createStatement: ""
        )
    }

    /// id(PK) / name / email
    static var idNameEmail: [TableColumn] {
        [
            column("id", "int", pk: true, nullable: false),
            column("name", "varchar", rawType: "varchar(255)"),
            column("email", "varchar", rawType: "varchar(255)"),
        ]
    }

    static func engine(
        columns: [TableColumn]? = nil,
        kind: DatabaseObjectKind = .table
    ) -> PendingChangeEngine {
        PendingChangeEngine(
            table: table,
            structure: structure(columns ?? idNameEmail, kind: kind)
        )
    }

    static func locator(_ columns: [String], _ values: [CellValue]) -> RowLocator {
        RowLocator(columns: columns, values: values)
    }
}

// MARK: - 合并规则

/// 覆盖 docs/tech-designs/08-pending-changes.md §2.2 的整张合并表与错误边界。
final class PendingChangeEngineTests: XCTestCase {

    private let row = RowIdentity.existing("1")

    private func idLocator(_ value: String = "1") -> RowLocator {
        PendingTestFixtures.locator(["id"], [.text(value)])
    }

    // MARK: 初始状态

    func testNoChangesInitially() {
        let engine = PendingTestFixtures.engine()
        XCTAssertTrue(engine.isEmpty)
        XCTAssertEqual(engine.stats, PendingChangeStats())
        XCTAssertEqual(engine.stats.summary, "无改动")
        XCTAssertNil(engine.change(for: row))
    }

    // MARK: 修改

    func testEditCreatesUpdate() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(
            row: row,
            locator: idLocator("1"),
            column: "name",
            originalValue: .text("old"),
            newValue: .text("new")
        )

        let change = engine.change(for: row)
        XCTAssertEqual(change?.kind, .update)
        XCTAssertEqual(change?.values["name"], .text("new"))
        XCTAssertEqual(change?.baseValues["name"], .text("old"))
        XCTAssertEqual(change?.locator, idLocator("1"))
        XCTAssertEqual(engine.stats.updates, 1)
        XCTAssertFalse(engine.isEmpty)
    }

    func testEditWithUnchangedValueIsNoop() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(
            row: row,
            locator: idLocator("1"),
            column: "name",
            originalValue: .text("same"),
            newValue: .text("same")
        )
        XCTAssertTrue(engine.isEmpty, "值没变不应产生改动")
    }

    func testSecondColumnMerges() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("n0"), newValue: .text("n1"))
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "email",
                             originalValue: .text("e0"), newValue: .text("e1"))

        XCTAssertEqual(engine.changes.count, 1, "同一行只应有一条 change")
        let change = engine.change(for: row)
        XCTAssertEqual(change?.values.count, 2)
        XCTAssertEqual(change?.values["name"], .text("n1"))
        XCTAssertEqual(change?.values["email"], .text("e1"))
        XCTAssertEqual(engine.stats.updates, 1)
    }

    func testRevertOnlyColumnRemovesChange() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("old"), newValue: .text("new"))
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("old"), newValue: .text("old"))

        XCTAssertTrue(engine.isEmpty, "唯一的改动被改回原值，行应恢复干净")
        XCTAssertEqual(engine.stats, PendingChangeStats())
    }

    func testRevertOneOfTwoColumnsKeepsChange() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("n0"), newValue: .text("n1"))
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "email",
                             originalValue: .text("e0"), newValue: .text("e1"))
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("n0"), newValue: .text("n0"))

        let change = engine.change(for: row)
        XCTAssertEqual(change?.values.count, 1)
        XCTAssertNil(change?.values["name"])
        XCTAssertEqual(change?.values["email"], .text("e1"))
    }

    func testLaterEditWins() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("old"), newValue: .text("v1"))
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("old"), newValue: .text("v2"))

        XCTAssertEqual(engine.change(for: row)?.values["name"], .text("v2"))
        XCTAssertEqual(engine.change(for: row)?.baseValues["name"], .text("old"))
    }

    // MARK: 新增

    func testBeginInsertIdentity() {
        var engine = PendingTestFixtures.engine()
        let inserted = engine.beginInsert()
        XCTAssertTrue(inserted.isInserted)
        XCTAssertNotNil(inserted.insertID)
        XCTAssertNil(inserted.keyString)
        XCTAssertEqual(engine.change(for: inserted)?.kind, .insert)
        XCTAssertEqual(engine.stats.inserts, 1)
    }

    func testInsertThenEditMerges() throws {
        var engine = PendingTestFixtures.engine()
        let inserted = engine.beginInsert()
        engine.setInsertValue(row: inserted, column: "name", value: .text("a"))
        // 字段栏在新增行上继续编辑
        try engine.applyEdit(
            row: inserted,
            locator: RowLocator(columns: [], values: []),
            column: "email",
            originalValue: .null,
            newValue: .text("b")
        )

        XCTAssertEqual(engine.changes.count, 1)
        XCTAssertEqual(engine.change(for: inserted)?.kind, .insert)
        XCTAssertEqual(engine.change(for: inserted)?.values.count, 2)
    }

    func testInsertThenDeleteRemovesChangeAndProducesNoSQL() {
        var engine = PendingTestFixtures.engine()
        let inserted = engine.beginInsert()
        engine.setInsertValue(row: inserted, column: "name", value: .text("a"))
        engine.applyDelete(row: inserted, locator: RowLocator(columns: [], values: []))

        XCTAssertTrue(engine.isEmpty)
        XCTAssertTrue(engine.sqlStatements(using: .conservative).isEmpty)
    }

    func testCancelInsertRemovesChange() {
        var engine = PendingTestFixtures.engine()
        let inserted = engine.beginInsert()
        engine.cancelInsert(row: inserted)
        XCTAssertTrue(engine.isEmpty)
    }

    func testSetInsertValueOnMissingRowIsIgnored() {
        var engine = PendingTestFixtures.engine()
        engine.setInsertValue(row: .inserted(), column: "name", value: .text("x"))
        XCTAssertTrue(engine.isEmpty)
    }

    // MARK: 删除

    func testUpdateThenDeleteReplacesWithDelete() throws {
        var engine = PendingTestFixtures.engine()
        try engine.applyEdit(row: row, locator: idLocator("5"), column: "id",
                             originalValue: .text("5"), newValue: .text("6"))
        // 主键已被改过；删除时 UI 传来的定位键可能是新值，但必须沿用冻结的旧值
        engine.applyDelete(row: row, locator: idLocator("6"))

        let change = engine.change(for: row)
        XCTAssertEqual(change?.kind, .delete)
        XCTAssertEqual(change?.locator, idLocator("5"))
        XCTAssertEqual(engine.stats.updates, 0)
        XCTAssertEqual(engine.stats.deletes, 1)
    }

    func testDeleteIsIdempotent() {
        var engine = PendingTestFixtures.engine()
        engine.applyDelete(row: row, locator: idLocator("7"))
        engine.applyDelete(row: row, locator: idLocator("7"))
        XCTAssertEqual(engine.changes.count, 1)
        XCTAssertEqual(engine.stats.deletes, 1)
    }

    func testDeleteThenEditThrowsRowAlreadyDeleted() {
        var engine = PendingTestFixtures.engine()
        engine.applyDelete(row: row, locator: idLocator("7"))

        XCTAssertThrowsError(
            try engine.applyEdit(row: row, locator: idLocator("7"), column: "name",
                                 originalValue: .text("a"), newValue: .text("b"))
        ) { error in
            XCTAssertEqual(error as? PendingChangeError, .rowAlreadyDeleted)
        }
    }

    // MARK: 撤销 / 放弃

    func testUndoRemovesOnlyThatRow() throws {
        var engine = PendingTestFixtures.engine()
        let other = RowIdentity.existing("2")
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("a"), newValue: .text("b"))
        try engine.applyEdit(row: other, locator: idLocator("2"), column: "name",
                             originalValue: .text("c"), newValue: .text("d"))

        engine.undo(row: row)
        XCTAssertNil(engine.change(for: row))
        XCTAssertNotNil(engine.change(for: other))
        XCTAssertEqual(engine.stats.updates, 1)
    }

    func testDiscardAll() throws {
        var engine = PendingTestFixtures.engine()
        _ = engine.beginInsert()
        try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                             originalValue: .text("a"), newValue: .text("b"))
        engine.discardAll()
        XCTAssertTrue(engine.isEmpty)
        XCTAssertEqual(engine.stats, PendingChangeStats())
    }

    // MARK: 统计

    func testStatsCountsEachKind() {
        var engine = PendingTestFixtures.engine()
        _ = engine.beginInsert()
        engine.applyDelete(row: RowIdentity.existing("9"), locator: idLocator("9"))
        XCTAssertEqual(engine.stats, PendingChangeStats(inserts: 1, updates: 0, deletes: 1))
        XCTAssertEqual(engine.stats.total, 2)
        XCTAssertEqual(engine.stats.summary, "1 新增 · 1 删除")
    }

    // MARK: 可编辑性 / 定位

    func testEditOnTableWithoutPrimaryKeyThrowsNotEditable() {
        var engine = PendingTestFixtures.engine(columns: [
            PendingTestFixtures.column("name", "varchar", rawType: "varchar(255)"),
        ])
        XCTAssertThrowsError(
            try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                                 originalValue: .text("a"), newValue: .text("b"))
        ) { error in
            XCTAssertEqual(error as? PendingChangeError, .notEditable("该表没有主键，无法安全定位行"))
        }
    }

    func testEditOnViewThrowsNotEditable() {
        var engine = PendingTestFixtures.engine(columns: [
            PendingTestFixtures.column("id", "int", pk: true),
            PendingTestFixtures.column("name", "varchar", rawType: "varchar(255)"),
        ], kind: .view)
        XCTAssertThrowsError(
            try engine.applyEdit(row: row, locator: idLocator("1"), column: "name",
                                 originalValue: .text("a"), newValue: .text("b"))
        ) { error in
            XCTAssertEqual(error as? PendingChangeError, .notEditable("视图不可编辑"))
        }
    }

    func testEditWithEmptyLocatorThrowsPrimaryKeyMissing() {
        var engine = PendingTestFixtures.engine()
        XCTAssertThrowsError(
            try engine.applyEdit(row: row, locator: RowLocator(columns: [], values: []), column: "name",
                                 originalValue: .text("a"), newValue: .text("b"))
        ) { error in
            XCTAssertEqual(error as? PendingChangeError, .primaryKeyMissing)
        }
    }

    func testDeleteOnTableWithoutPrimaryKeyIsIgnored() {
        var engine = PendingTestFixtures.engine(columns: [
            PendingTestFixtures.column("name", "varchar", rawType: "varchar(255)"),
        ])
        engine.applyDelete(row: row, locator: PendingTestFixtures.locator(["name"], [.text("a")]))
        XCTAssertTrue(engine.isEmpty, "不可编辑的表不应记录删除，避免无 WHERE 的语句")
    }
}

// MARK: - Store 包装

/// `PendingChangeStore` 只是引擎的 @MainActor 包装，重点验证转发与统计同步。
@MainActor
final class PendingChangeStoreTests: XCTestCase {

    private let row = RowIdentity.existing("1")

    private func makeStore() -> PendingChangeStore {
        PendingChangeStore(table: PendingTestFixtures.table,
                           structure: PendingTestFixtures.structure(PendingTestFixtures.idNameEmail))
    }

    func testApplyEditUpdatesStatsAndDirty() throws {
        let store = makeStore()
        XCTAssertFalse(store.isDirty(row))
        try store.applyEdit(row: row,
                            locator: PendingTestFixtures.locator(["id"], [.text("1")]),
                            column: "name",
                            originalValue: .text("a"),
                            newValue: .text("b"))
        XCTAssertTrue(store.isDirty(row))
        XCTAssertEqual(store.stats.updates, 1)
        XCTAssertEqual(store.change(for: row)?.values["name"], .text("b"))
    }

    func testStoreRevertClearsDirty() throws {
        let store = makeStore()
        let locator = PendingTestFixtures.locator(["id"], [.text("1")])
        try store.applyEdit(row: row, locator: locator, column: "name",
                            originalValue: .text("a"), newValue: .text("b"))
        try store.applyEdit(row: row, locator: locator, column: "name",
                            originalValue: .text("a"), newValue: .text("a"))
        XCTAssertFalse(store.isDirty(row))
        XCTAssertTrue(store.isEmpty)
    }

    func testOriginalValueUsesFrozenBase() throws {
        let store = makeStore()
        let locator = PendingTestFixtures.locator(["id"], [.text("1")])
        try store.applyEdit(row: row, locator: locator, column: "name",
                            originalValue: .text("base"), newValue: .text("changed"))
        // 即便调用方给的 fallback 变了，也以冻结的基准值为准
        XCTAssertEqual(store.originalValue(row: row, column: "name", fallback: .text("other")),
                       .text("base"))
        XCTAssertEqual(store.originalValue(row: row, column: "absent", fallback: .text("fb")),
                       .text("fb"))
    }

    func testStoreInsertAndCancel() {
        let store = makeStore()
        let inserted = store.beginInsert()
        store.setInsertValue(row: inserted, column: "name", value: .text("x"))
        XCTAssertEqual(store.stats.inserts, 1)
        store.cancelInsert(row: inserted)
        XCTAssertTrue(store.isEmpty)
    }

    func testStoreDiscardAll() throws {
        let store = makeStore()
        try store.applyEdit(row: row,
                            locator: PendingTestFixtures.locator(["id"], [.text("1")]),
                            column: "name",
                            originalValue: .text("a"),
                            newValue: .text("b"))
        store.discardAll()
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.stats, PendingChangeStats())
    }

    func testStoreSQLStatementsMatchEngine() throws {
        let store = makeStore()
        try store.applyEdit(row: row,
                            locator: PendingTestFixtures.locator(["id"], [.text("1")]),
                            column: "name",
                            originalValue: .text("a"),
                            newValue: .text("b"))
        let statements = store.sqlStatements(using: .conservative)
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].text,
                       "UPDATE `app_dev`.`users` SET `name` = 'b' WHERE `id` = 1")
    }
}

// MARK: - 提交防线（不需要真实数据库）

/// 只覆盖不需要真库的提交边界；真正的提交/回滚需要 MySQL，见 docs/tech-designs/15-testing.md 分层。
final class PendingChangeCommitterTests: XCTestCase {

    private func makeSession() -> MySQLSession {
        MySQLSession(
            configuration: MySQLSession.Configuration(
                mysql: MySQLConnectConfig(),
                password: nil,
                host: "127.0.0.1",
                port: 3306
            ),
            clock: InMemoryClock()
        )
    }

    private func statement(_ text: String, kind: PendingRowChange.Kind = .update) -> PendingSQLStatement {
        PendingSQLStatement(id: 1, text: text, kind: kind, identity: .existing("1"))
    }

    func testEmptyStatementsReturnsImmediately() async throws {
        let committer = PendingChangeCommitter(session: makeSession())
        let outcome = try await committer.commit([], clock: InMemoryClock()) { _, _ in }
        XCTAssertEqual(outcome.executedCount, 0)
        XCTAssertTrue(outcome.zeroRowStatements.isEmpty)
    }

    func testRejectsNonDMLStatement() async {
        let committer = PendingChangeCommitter(session: makeSession())
        do {
            _ = try await committer.commit(
                [statement("ALTER TABLE `users` ADD COLUMN x INT")],
                clock: InMemoryClock()
            ) { _, _ in }
            XCTFail("结构变更语句必须被拒绝")
        } catch let error as MySQLError {
            if case .unsupported(let message) = error {
                XCTAssertEqual(message, PendingChangeCommitter.unsupportedStatementMessage)
            } else {
                XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testRejectsLowercaseDDL() async {
        let committer = PendingChangeCommitter(session: makeSession())
        do {
            _ = try await committer.commit(
                [statement("  create table t (id int)")],
                clock: InMemoryClock()
            ) { _, _ in }
            XCTFail("结构变更语句必须被拒绝")
        } catch let error as MySQLError {
            guard case .unsupported = error else {
                return XCTFail("错误类型不对：\(error)")
            }
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testIsDMLDetection() {
        XCTAssertTrue(PendingChangeCommitter.isDML("INSERT INTO t () VALUES ()"))
        XCTAssertTrue(PendingChangeCommitter.isDML("  update t set a = 1"))
        XCTAssertTrue(PendingChangeCommitter.isDML("Delete FROM t"))
        XCTAssertFalse(PendingChangeCommitter.isDML(""))
        XCTAssertFalse(PendingChangeCommitter.isDML("   "))
        XCTAssertFalse(PendingChangeCommitter.isDML("SELECT 1"))
        XCTAssertFalse(PendingChangeCommitter.isDML("ALTER TABLE t"))
        XCTAssertFalse(PendingChangeCommitter.isDML("WITH x AS (SELECT 1) DELETE FROM t"))
    }
}
