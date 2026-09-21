import XCTest
@testable import TableLite

/// `MetaRepository` 真库集成测试：库 / 对象 / 表结构 / 行数 / TTL 缓存 / DDL 失效。
///
/// 环境变量约定见 `IntegrationSupport.swift`；未设置 `MYSQL_HOST` 时整类跳过。
/// 设计约束见 docs/tech-designs/11-schema-and-import-export.md §1。
final class MetaRepositoryIntegrationTests: MySQLIntegrationTestCase {

    override class var databaseName: String { "tablelite_it_meta" }

    private func makeRepository() -> MetaRepository {
        MetaRepository(session: session, clock: LiveClock())
    }

    // MARK: 库列表

    func testDatabasesIncludesCreatedDatabaseAndFiltersSystem() async throws {
        let meta = makeRepository()

        let userDatabases = try await meta.databases(includeSystem: false)
        XCTAssertTrue(userDatabases.contains(Self.databaseName),
                      "应当列出本用例创建的库，实得 \(userDatabases)")
        for system in ["information_schema", "performance_schema", "mysql", "sys"] {
            XCTAssertFalse(userDatabases.contains(system), "系统库 \(system) 应当被过滤")
        }

        let all = try await meta.databases(includeSystem: true)
        XCTAssertTrue(all.contains("information_schema"))
        XCTAssertTrue(all.contains(Self.databaseName))
    }

    // MARK: 对象列表

    func testObjectsListsTableAndView() async throws {
        try await session.execute("CREATE TABLE \(qualified("t_obj")) (id INT PRIMARY KEY, v INT)")
        try await session.execute("""
            CREATE VIEW \(qualified("v_obj")) AS SELECT id FROM \(qualified("t_obj"))
            """)

        let objects = try await makeRepository().objects(database: Self.databaseName)
        let names = objects.map(\.name)
        XCTAssertTrue(names.contains("t_obj"))
        XCTAssertTrue(names.contains("v_obj"))

        XCTAssertEqual(objects.first { $0.name == "t_obj" }?.kind, .table)
        XCTAssertEqual(objects.first { $0.name == "v_obj" }?.kind, .view)
        // 视图没有行数估算
        XCTAssertNil(objects.first { $0.name == "v_obj" }?.rowEstimate)
    }

    // MARK: 表结构

    func testStructureReadsColumnsIndexesForeignKeysTriggersAndCreate() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("parent")) (
              id INT PRIMARY KEY,
              code VARCHAR(32) NOT NULL,
              UNIQUE KEY uq_code (code)
            ) COMMENT='parent table'
            """)
        try await session.execute("""
            CREATE TABLE \(qualified("child")) (
              id INT PRIMARY KEY AUTO_INCREMENT,
              parent_id INT NOT NULL,
              note VARCHAR(64) DEFAULT NULL,
              body LONGTEXT,
              CONSTRAINT fk_child_parent FOREIGN KEY (parent_id)
                REFERENCES \(qualified("parent")) (id)
                ON DELETE CASCADE ON UPDATE RESTRICT
            ) COMMENT='child table'
            """)
        try await session.execute("""
            CREATE TRIGGER \(SQLIdentifier.quote("trg_child")) BEFORE INSERT ON \(qualified("child"))
            FOR EACH ROW SET NEW.note = COALESCE(NEW.note, 'auto')
            """)

        let meta = makeRepository()
        let child = try await meta.structure(TableRef(database: Self.databaseName, table: "child"))

        XCTAssertEqual(child.kind, .table)
        XCTAssertEqual(child.comment, "child table")
        XCTAssertEqual(child.columns.map(\.name), ["id", "parent_id", "note", "body"])

        let id = try XCTUnwrap(child.columns.first { $0.name == "id" })
        XCTAssertTrue(id.isPrimaryKey)
        XCTAssertTrue(id.isAutoIncrement)
        XCTAssertEqual(id.kind, .integer(isUnsigned: false))

        let body = try XCTUnwrap(child.columns.first { $0.name == "body" })
        XCTAssertTrue(body.isLargeObject)

        XCTAssertEqual(child.primaryKeyColumns.map(\.name), ["id"])
        XCTAssertTrue(child.isEditableStructure)

        XCTAssertTrue(child.indexes.contains { $0.indexType == "PRIMARY" && $0.columns.map(\.name) == ["id"] },
                      "应当读到主键索引，实得 \(child.indexes)")

        let foreignKey = try XCTUnwrap(child.foreignKeys.first)
        XCTAssertEqual(foreignKey.name, "fk_child_parent")
        XCTAssertEqual(foreignKey.columns, ["parent_id"])
        XCTAssertEqual(foreignKey.referencedTable, "parent")
        XCTAssertEqual(foreignKey.referencedColumns, ["id"])
        XCTAssertEqual(foreignKey.onDelete.uppercased(), "CASCADE")
        XCTAssertEqual(foreignKey.onUpdate.uppercased(), "RESTRICT")

        let trigger = try XCTUnwrap(child.triggers.first { $0.name == "trg_child" })
        XCTAssertEqual(trigger.timing.uppercased(), "BEFORE")
        XCTAssertEqual(trigger.event.uppercased(), "INSERT")
        XCTAssertTrue(trigger.statement.contains("NEW.note"))

        XCTAssertTrue(child.createStatement.uppercased().contains("CREATE TABLE"))
        XCTAssertTrue(child.createStatement.contains("fk_child_parent"))

        // 被引用表也有 UNIQUE 索引
        let parent = try await meta.structure(TableRef(database: Self.databaseName, table: "parent"))
        XCTAssertEqual(parent.comment, "parent table")
        XCTAssertTrue(parent.indexes.contains { $0.indexType == "UNIQUE" && $0.name == "uq_code" })
    }

    // MARK: 视图结构

    func testViewStructureIsNotEditable() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_base")) (id INT PRIMARY KEY, v VARCHAR(10))
            """)
        try await session.execute("""
            CREATE VIEW \(qualified("v_struct")) AS SELECT id, v FROM \(qualified("t_base"))
            """)

        let view = try await makeRepository().structure(TableRef(database: Self.databaseName,
                                                                table: "v_struct"))
        XCTAssertEqual(view.kind, .view)
        XCTAssertEqual(view.columns.map(\.name), ["id", "v"])
        XCTAssertTrue(view.primaryKeyColumns.isEmpty)
        XCTAssertFalse(view.isEditableStructure, "视图不可编辑")
        XCTAssertTrue(view.createStatement.uppercased().contains("VIEW"))
    }

    // MARK: 行数

    func testRowEstimateAndPreciseCount() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_count")) (
              id INT PRIMARY KEY AUTO_INCREMENT,
              v INT NOT NULL
            )
            """)
        let tuples = (1...37).map { "(\($0))" }.joined(separator: ", ")
        try await session.execute("INSERT INTO \(qualified("t_count")) (v) VALUES \(tuples)")

        let meta = makeRepository()
        let ref = TableRef(database: Self.databaseName, table: "t_count")

        let precise = try await meta.preciseCount(ref, whereClause: nil)
        XCTAssertEqual(precise, 37)

        let filtered = try await meta.preciseCount(ref, whereClause: "`v` > 10")
        XCTAssertEqual(filtered, 27)

        let estimate = try await meta.rowEstimate(ref)
        XCTAssertNotNil(estimate, "InnoDB 的 TABLE_ROWS 估算应当可读")
    }

    // MARK: 缓存 TTL

    func testStructureCacheHitAndDDLInvalidation() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_cache")) (id INT PRIMARY KEY, v VARCHAR(10))
            """)
        let ref = TableRef(database: Self.databaseName, table: "t_cache")
        let meta = makeRepository()

        let counter = QueryCounter()
        await session.setQueryLogger { record in counter.record(record.sql) }

        _ = try await meta.structure(ref)
        let firstColumnsQueries = counter.count(matching: "information_schema.COLUMNS")
        let firstTablesQueries = counter.count(matching: "information_schema.TABLES")
        XCTAssertGreaterThan(firstColumnsQueries, 0)

        _ = try await meta.structure(ref)
        XCTAssertEqual(counter.count(matching: "information_schema.COLUMNS"), firstColumnsQueries,
                       "第二次 structure 应命中 5 分钟缓存，不再发查询")
        XCTAssertEqual(counter.count(matching: "information_schema.TABLES"), firstTablesQueries,
                       "表信息查询不应在缓存命中时重发")

        // 真实 DROP 并通知，缓存必须失效：再读结构会因表不存在而抛错。
        try await session.execute("DROP TABLE \(qualified("t_cache"))")
        await meta.noteExecutedSQL("DROP TABLE `t_cache`")

        var threw = false
        do {
            _ = try await meta.structure(ref)
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "DROP TABLE 之后表结构缓存必须失效，不应返回旧结构")
    }

    func testRowEstimateCacheTTL() async throws {
        try await session.execute("""
            CREATE TABLE \(qualified("t_est_cache")) (id INT PRIMARY KEY, v INT)
            """)
        let ref = TableRef(database: Self.databaseName, table: "t_est_cache")
        let meta = makeRepository()

        let counter = QueryCounter()
        await session.setQueryLogger { record in counter.record(record.sql) }

        _ = try await meta.rowEstimate(ref)
        let first = counter.count(matching: "information_schema.TABLES")
        _ = try await meta.rowEstimate(ref)
        XCTAssertEqual(counter.count(matching: "information_schema.TABLES"), first,
                       "30 秒内第二次行数估算应命中缓存")
    }

    func testDDLInvalidationRefreshesObjectsAndStructure() async throws {
        let meta = makeRepository()
        let ref = TableRef(database: Self.databaseName, table: "t_ddl")

        let initial = try await meta.objects(database: Self.databaseName)
        XCTAssertFalse(initial.contains { $0.name == "t_ddl" })

        try await session.execute("CREATE TABLE \(qualified("t_ddl")) (id INT PRIMARY KEY)")
        await meta.noteExecutedSQL("CREATE TABLE `\(Self.databaseName)`.`t_ddl` (`id` INT PRIMARY KEY)")
        let afterCreate = try await meta.objects(database: Self.databaseName)
        XCTAssertTrue(afterCreate.contains { $0.name == "t_ddl" }, "CREATE 应当失效对象列表缓存")
        let columnsAfterCreate = try await meta.structure(ref).columns.map(\.name)
        XCTAssertEqual(columnsAfterCreate, ["id"])

        try await session.execute("ALTER TABLE \(qualified("t_ddl")) ADD COLUMN v VARCHAR(10)")
        await meta.noteExecutedSQL("ALTER TABLE `t_ddl` ADD COLUMN v VARCHAR(10)")
        let columnsAfterAlter = try await meta.structure(ref).columns.map(\.name)
        XCTAssertEqual(columnsAfterAlter, ["id", "v"],
                       "ALTER 应当失效表结构缓存")
    }
}
