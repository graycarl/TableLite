import XCTest
@testable import TableLite

/// 结构视图数据来源替身。
actor FakeTableStructureProvider: TableStructureProviding {

    private var structureResult: TableStructure?
    private var structureError: MySQLError?

    private(set) var loadStructureCalls: [(database: String, table: String, kind: TableKind, forceRefresh: Bool)] = []

    func setStructure(_ structure: TableStructure) {
        structureResult = structure
        structureError = nil
    }

    func setStructureError(_ error: MySQLError) {
        structureError = error
    }

    var lastForceRefresh: Bool? { loadStructureCalls.last?.forceRefresh }

    func loadStructure(
        database: String,
        table: String,
        kind: TableKind,
        forceRefresh: Bool
    ) async throws -> TableStructure {
        loadStructureCalls.append((database, table, kind, forceRefresh))
        if let structureError { throw structureError }
        guard let structureResult else {
            throw MySQLError.server(code: 0, sqlState: "", message: "没有脚本化结构结果")
        }
        return structureResult
    }
}

/// 剪贴板替身。
@MainActor
final class FakeSchemaClipboard: SchemaClipboard {
    private(set) var written: [String] = []
    func write(_ text: String) { written.append(text) }
}

/// `TableStructureViewModel`：加载 / 刷新 / 过期 / 分页签 / 复制 / 错误路径。
@MainActor
final class TableStructureViewModelTests: XCTestCase {

    // MARK: 装配

    private func makeSession(_ harness: SessionTestHarness) async throws -> ConnectionSession {
        await harness.mysql.setResponses(SessionTestSupport.successfulResponses())
        return try await harness.manager.connect(SessionTestSupport.connection(), password: nil)
    }

    private func makeStructure(
        kind: TableKind = .table,
        createStatement: String? = "CREATE TABLE `users` (\n  `id` bigint unsigned NOT NULL AUTO_INCREMENT,\n  PRIMARY KEY (`id`)\n);"
    ) -> TableStructure {
        var id = ColumnInfo(name: "id", fieldType: .longlong)
        id.flags = ColumnFlag.primaryKey | ColumnFlag.autoIncrement
        id.columnTypeText = "bigint unsigned"
        id.isNullable = false
        id.hasDefaultValue = false
        id.ordinalPosition = 1

        var name = ColumnInfo(name: "name", fieldType: .varString)
        name.columnTypeText = "varchar(255)"
        name.isNullable = true
        name.columnDefault = nil
        name.hasDefaultValue = false
        name.characterSet = "utf8mb4"
        name.collation = "utf8mb4_general_ci"
        name.comment = "显示名"
        name.ordinalPosition = 2

        return TableStructure(
            table: TableInfo(
                database: "app_dev",
                name: kind == .view ? "v_users" : "users",
                kind: kind,
                rowCountEstimate: 12480
            ),
            columns: [id, name],
            indexes: [
                IndexInfo(name: "PRIMARY", kind: .primary, columns: [IndexColumn(name: "id")], cardinality: 12480),
            ],
            foreignKeys: [
                ForeignKeyInfo(
                    name: "fk_orders_user",
                    columns: ["user_id"],
                    referencedDatabase: nil,
                    referencedTable: "users",
                    referencedColumns: ["id"],
                    onDelete: "CASCADE",
                    onUpdate: "RESTRICT"
                ),
            ],
            triggers: [
                TriggerInfo(
                    name: "trg_users_ai",
                    timing: .after,
                    event: .insert,
                    statement: "BEGIN\n  INSERT INTO audit_log …\nEND"
                ),
            ],
            createStatement: createStatement
        )
    }

    // MARK: 加载

    func testStartLoadsStructure() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"))

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure())

        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)
        await model.start()

        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.structure?.columns.count, 2)
        XCTAssertEqual(model.statusSummary, "2 列 · 1 索引 · 1 外键 · 1 触发器")
        let calls = await provider.loadStructureCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.kind, .table)
        XCTAssertEqual(calls.first?.forceRefresh, false)
    }

    /// 用真实 `LiveTableStructureProvider` + `MetaRepository` + `FakeMySQLSession` 跑一遍，
    /// 验证默认接线（不注入替身）也能拿到列 / 索引 / 建表语句 / 行数。
    func testDefaultProviderLoadsViaMetaRepository() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)

        await harness.mysql.setResponses([
            ("information_schema.COLUMNS", .single(
                columns: ["COLUMN_NAME", "ORDINAL_POSITION", "IS_NULLABLE", "DATA_TYPE", "COLUMN_TYPE", "COLUMN_KEY", "EXTRA"],
                rows: [["id", "1", "NO", "bigint", "bigint unsigned", "PRI", "auto_increment"]]
            )),
            ("information_schema.STATISTICS", .single(
                columns: ["INDEX_NAME", "SEQ_IN_INDEX", "COLUMN_NAME", "NON_UNIQUE", "INDEX_TYPE"],
                rows: [["PRIMARY", "1", "id", "0", "BTREE"]]
            )),
            ("information_schema.KEY_COLUMN_USAGE", .single(
                columns: ["CONSTRAINT_NAME", "COLUMN_NAME", "ORDINAL_POSITION", "REFERENCED_TABLE_SCHEMA", "REFERENCED_TABLE_NAME", "REFERENCED_COLUMN_NAME", "UPDATE_RULE", "DELETE_RULE"],
                rows: []
            )),
            ("information_schema.TRIGGERS", .single(
                columns: ["TRIGGER_NAME", "ACTION_TIMING", "EVENT_MANIPULATION", "ACTION_STATEMENT"],
                rows: []
            )),
            ("SHOW CREATE TABLE", .single(
                columns: ["Table", "Create Table"],
                rows: [["users", "CREATE TABLE `users` (`id` bigint NOT NULL);"]]
            )),
            ("TABLE_ROWS, TABLE_TYPE", .single(columns: ["TABLE_ROWS", "TABLE_TYPE"], rows: [["10", "BASE TABLE"]])),
        ])

        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"))
        let model = TableStructureViewModel(session: session, tab: tab)
        await model.start()

        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.structure?.columns.count, 1)
        XCTAssertEqual(model.structure?.indexes.first?.kind, .primary)
        XCTAssertEqual(model.structure?.createStatement, "CREATE TABLE `users` (`id` bigint NOT NULL);")
    }

    func testStartIsIdempotent() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"))

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure())
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)

        await model.start()
        await model.start()

        let calls = await provider.loadStructureCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testStaleTabForcesRefreshAndClearsFlag() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"), isStale: true)

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure())
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)

        XCTAssertTrue(model.isStale)
        await model.start()

        let lastForceRefresh = await provider.lastForceRefresh
        XCTAssertEqual(lastForceRefresh, true)
        XCTAssertFalse(tab.isStale)
        XCTAssertFalse(model.isStale)
    }

    func testRefreshInvalidatesMetaAndForcesReload() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"))

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure())
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)

        await model.start()
        await model.refresh()

        let calls = await provider.loadStructureCalls
        XCTAssertEqual(calls.map { $0.forceRefresh }, [false, true])
    }

    // MARK: 错误

    func testLoadFailureExposesStructuredError() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"))

        let provider = FakeTableStructureProvider()
        await provider.setStructureError(
            MySQLError.server(code: 1146, sqlState: "42S02", message: "Table 'app_dev.users' doesn't exist")
        )
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)
        await model.start()

        XCTAssertEqual(model.loadState, .failed)
        XCTAssertEqual(model.loadError?.code, 1146)
        XCTAssertEqual(model.loadError?.sqlState, "42S02")
        // 服务器原文不翻译、不改写。
        XCTAssertEqual(model.loadError?.message, "Table 'app_dev.users' doesn't exist")
    }

    // MARK: 子页签

    func testPagesForTable() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"))

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure())
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)
        await model.start()

        XCTAssertEqual(model.pages, SchemaStructurePage.allCases)
        XCTAssertEqual(model.definitionPageTitle, "建表语句")
        XCTAssertTrue(model.isTableStructureTab)
        XCTAssertFalse(model.isObjectDefinitionTab)
    }

    /// 视图在对象树里「打开结构」也走 `.tableStructure` 标签；
    /// 结构还没加载时就要从对象目录里认出视图（`specs/07-schema-view.md` §3）。
    func testTableStructureTabResolvesViewKindFromObjectCatalog() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        await harness.mysql.setResponses([
            ("SHOW DATABASES", .single(columns: ["Database"], rows: [["app_dev"]])),
            ("@@character_set_server", .single(
                columns: ["version", "server_charset", "server_collation", "sql_mode", "client_charset", "connection_collation"],
                rows: [["8.0.36", "utf8mb4", "utf8mb4_0900_ai_ci", "", "utf8mb4", "utf8mb4_general_ci"]]
            )),
            ("TABLE_COLLATION", .single(
                columns: ["TABLE_NAME", "TABLE_TYPE", "ENGINE", "TABLE_ROWS", "TABLE_COMMENT", "TABLE_COLLATION"],
                rows: [["v_users", "VIEW", nil, nil, nil, nil]]
            )),
        ])
        let session = try await harness.manager.connect(SessionTestSupport.connection(), password: nil)

        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "v_users"))
        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure(kind: .view))
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)

        XCTAssertTrue(model.isView)
        XCTAssertTrue(model.isTableStructureTab)
        XCTAssertEqual(model.pages, [.columns, .definition])

        await model.start()
        let calls = await provider.loadStructureCalls
        XCTAssertEqual(calls.first?.kind, .view)
    }

    func testViewShowsColumnsAndDefinitionOnly() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "v_users"))

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure(kind: .view))
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)
        await model.start()

        XCTAssertTrue(model.isView)
        XCTAssertEqual(model.pages, [.columns, .definition])
        XCTAssertEqual(model.definitionPageTitle, "定义")
        let calls = await provider.loadStructureCalls
        XCTAssertEqual(calls.first?.kind, .table)
    }

    func testObjectDefinitionTabIsDefinitionOnly() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .objectDefinition(database: "app_dev", object: "v_users"))

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure(kind: .view))
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)
        await model.start()

        XCTAssertTrue(model.isObjectDefinitionTab)
        XCTAssertEqual(model.pages, [.definition])
        XCTAssertEqual(model.definitionPageTitle, "定义")
        let calls = await provider.loadStructureCalls
        XCTAssertEqual(calls.first?.kind, .view)
        XCTAssertEqual(model.selectedPage, .definition)
    }

    // MARK: 操作

    func testCopyDefinitionWritesClipboard() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"))

        let provider = FakeTableStructureProvider()
        let sql = "CREATE TABLE `users` (`id` bigint NOT NULL);"
        await provider.setStructure(makeStructure(createStatement: sql))
        let clipboard = FakeSchemaClipboard()
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider, clipboard: clipboard)
        await model.start()

        model.copyDefinition()

        XCTAssertEqual(clipboard.written, [sql])
        XCTAssertEqual(model.copyNotice, "已复制建表语句")
    }

    func testCopyDefinitionWithoutStatementDoesNothing() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "users"))

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure(createStatement: nil))
        let clipboard = FakeSchemaClipboard()
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider, clipboard: clipboard)
        await model.start()

        model.copyDefinition()

        XCTAssertTrue(clipboard.written.isEmpty)
        XCTAssertNil(model.copyNotice)
        XCTAssertTrue(model.isEmptyDefinition)
    }

    func testEditDefinitionOpensQueryTab() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .objectDefinition(database: "app_dev", object: "v_users"))

        let provider = FakeTableStructureProvider()
        let sql = "CREATE VIEW `v_users` AS SELECT * FROM `users`;"
        await provider.setStructure(makeStructure(kind: .view, createStatement: sql))
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)
        await model.start()

        model.editDefinitionInNewQuery()

        let queryTab = session.tabs.first { $0.kind.isQuery }
        XCTAssertNotNil(queryTab)
        XCTAssertEqual(queryTab?.initialSQL, sql)
    }

    func testOpenReferencedTableOpensDataTab() async throws {
        let harness = SessionTestSupport.makeHarness()
        defer { harness.clean() }
        let session = try await makeSession(harness)
        let tab = Tab(kind: .tableStructure(database: "app_dev", table: "orders"))

        let provider = FakeTableStructureProvider()
        await provider.setStructure(makeStructure())
        let model = TableStructureViewModel(session: session, tab: tab, provider: provider)
        await model.start()

        let foreignKey = ForeignKeyInfo(
            name: "fk_orders_user",
            columns: ["user_id"],
            referencedDatabase: nil,
            referencedTable: "users",
            referencedColumns: ["id"]
        )
        model.openReferencedTable(foreignKey)

        XCTAssertTrue(session.tabs.contains { $0.kind == .tableData(database: "app_dev", table: "users") })
    }

    // MARK: 纯显示规则

    func testDefaultDisplayDistinguishesMissingFromNull() {
        var column = ColumnInfo(name: "email", fieldType: .varString)

        column.hasDefaultValue = false
        column.columnDefault = nil
        XCTAssertEqual(SchemaDisplay.defaultDisplay(column), "—")

        column.hasDefaultValue = true
        column.columnDefault = nil
        XCTAssertEqual(SchemaDisplay.defaultDisplay(column), "NULL")

        column.hasDefaultValue = true
        column.columnDefault = "draft"
        XCTAssertEqual(SchemaDisplay.defaultDisplay(column), "draft")

        column.hasDefaultValue = true
        column.columnDefault = ""
        XCTAssertEqual(SchemaDisplay.defaultDisplay(column), "''")
    }

    func testCharsetDisplayOnlyForTextColumns() {
        var column = ColumnInfo(name: "age", fieldType: .short)
        XCTAssertEqual(SchemaDisplay.charsetDisplay(column), "—")

        column.characterSet = "utf8mb4"
        column.collation = "utf8mb4_0900_ai_ci"
        XCTAssertEqual(SchemaDisplay.charsetDisplay(column), "utf8mb4 / utf8mb4_0900_ai_ci")

        column.collation = nil
        XCTAssertEqual(SchemaDisplay.charsetDisplay(column), "utf8mb4")
    }

    func testIndexColumnsDisplayMarksPrefixAndDescending() {
        let index = IndexInfo(
            name: "idx",
            kind: .normal,
            columns: [
                IndexColumn(name: "status"),
                IndexColumn(name: "created_at", isDescending: true),
                IndexColumn(name: "title", prefixLength: 20),
            ]
        )
        XCTAssertEqual(
            SchemaDisplay.indexColumnsDisplay(index),
            "`status`, `created_at` desc, `title`(20)"
        )
    }

    func testPlaceholderForEmptyValues() {
        XCTAssertEqual(SchemaDisplay.text(nil), "—")
        XCTAssertEqual(SchemaDisplay.text(""), "—")
        XCTAssertEqual(SchemaDisplay.text("主键"), "主键")
        XCTAssertEqual(SchemaDisplay.joined([]), "—")
        XCTAssertEqual(SchemaDisplay.check(true), "✓")
        XCTAssertEqual(SchemaDisplay.check(false), "")
    }
}
