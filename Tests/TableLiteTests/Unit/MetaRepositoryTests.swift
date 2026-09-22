import XCTest
import Synchronization
@testable import TableLite

/// `MetaRepository`：information_schema 查询、缓存 TTL、DDL 失效。
final class MetaRepositoryTests: XCTestCase {

    private func databasesResponse() -> MySQLQueryResult {
        .single(columns: ["Database"], rows: [["app_dev"], ["mysql"], ["information_schema"]])
    }

    private func objectsResponse() -> MySQLQueryResult {
        .single(
            columns: ["TABLE_NAME", "TABLE_TYPE", "ENGINE", "TABLE_ROWS", "TABLE_COMMENT", "TABLE_COLLATION"],
            rows: [
                ["users", "BASE TABLE", "InnoDB", "12480", "", "utf8mb4_general_ci"],
                ["v_users", "VIEW", nil, nil, nil, nil],
            ]
        )
    }

    func testDatabasesAreCachedAndFiltered() async throws {
        let fake = FakeMySQLSession()
        await fake.setResponses([("SHOW DATABASES", databasesResponse())])
        let clock = MutableClock()
        let repository = MetaRepository(session: fake, clock: clock)

        let all = try await repository.allDatabases()
        XCTAssertEqual(all, ["app_dev", "mysql", "information_schema"])
        let filtered = try await repository.databases(includeSystem: false)
        XCTAssertEqual(filtered, ["app_dev"])
        // 第二次读不再打库。
        _ = try await repository.allDatabases()
        let count = await fake.executedSQL.filter { $0.contains("SHOW DATABASES") }.count
        XCTAssertEqual(count, 1)
    }

    func testObjectsCachedForTTL() async throws {
        let fake = FakeMySQLSession()
        await fake.setResponses([
            ("SHOW DATABASES", databasesResponse()),
            ("TABLE_COLLATION", objectsResponse()),
        ])
        let clock = MutableClock()
        let repository = MetaRepository(session: fake, clock: clock)

        let first = try await repository.objects(database: "app_dev")
        XCTAssertEqual(first.map(\.name), ["users", "v_users"])
        _ = try await repository.objects(database: "app_dev")
        var count = await fake.executedSQL.filter { $0.contains("TABLE_COLLATION") }.count
        XCTAssertEqual(count, 1)

        // TTL 内仍然命中缓存。
        clock.advance(by: MetaRepository.objectsTTL - 1)
        _ = try await repository.objects(database: "app_dev")
        count = await fake.executedSQL.filter { $0.contains("TABLE_COLLATION") }.count
        XCTAssertEqual(count, 1)

        // 超过 TTL 重新查询。
        clock.advance(by: 2)
        _ = try await repository.objects(database: "app_dev")
        count = await fake.executedSQL.filter { $0.contains("TABLE_COLLATION") }.count
        XCTAssertEqual(count, 2)
    }

    func testStructureAggregatesAllParts() async throws {
        let fake = FakeMySQLSession()
        await fake.setResponses([
            ("TABLE_COLLATION", objectsResponse()),
            ("information_schema.COLUMNS", .single(
                columns: ["COLUMN_NAME", "ORDINAL_POSITION", "IS_NULLABLE", "DATA_TYPE", "COLUMN_TYPE", "COLUMN_KEY", "EXTRA"],
                rows: [
                    ["id", "1", "NO", "bigint", "bigint unsigned", "PRI", "auto_increment"],
                    ["name", "2", "YES", "varchar", "varchar(255)", "", ""],
                ]
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
                rows: [["users", "CREATE TABLE `users` (…);"]]
            )),
        ])
        let clock = MutableClock()
        let repository = MetaRepository(session: fake, clock: clock)

        let structure = try await repository.structure(database: "app_dev", table: "users")
        XCTAssertEqual(structure.columns.count, 2)
        XCTAssertEqual(structure.indexes.first?.kind, .primary)
        XCTAssertTrue(structure.foreignKeys.isEmpty)
        XCTAssertTrue(structure.triggers.isEmpty)
        XCTAssertEqual(structure.createStatement, "CREATE TABLE `users` (…);")
        XCTAssertEqual(structure.summary, "2 列 · 1 索引 · 0 外键 · 0 触发器")
    }

    func testRowCountEstimateUsesTTL() async throws {
        let fake = FakeMySQLSession()
        await fake.setResponses([
            ("TABLE_ROWS, TABLE_TYPE", .single(columns: ["TABLE_ROWS", "TABLE_TYPE"], rows: [["42", "BASE TABLE"]])),
        ])
        let clock = MutableClock()
        let repository = MetaRepository(session: fake, clock: clock)

        let estimate = try await repository.rowCountEstimate(database: "app_dev", table: "users")
        XCTAssertEqual(estimate, RowCountEstimate(approximate: 42, isReliable: true, isExact: false))
        clock.advance(by: MetaRepository.rowCountTTL - 1)
        _ = try await repository.rowCountEstimate(database: "app_dev", table: "users")
        var count = await fake.executedSQL.filter { $0.contains("TABLE_ROWS, TABLE_TYPE") }.count
        XCTAssertEqual(count, 1)

        clock.advance(by: 2)
        _ = try await repository.rowCountEstimate(database: "app_dev", table: "users")
        count = await fake.executedSQL.filter { $0.contains("TABLE_ROWS, TABLE_TYPE") }.count
        XCTAssertEqual(count, 2)
    }

    func testServerInfo() async throws {
        let fake = FakeMySQLSession()
        await fake.setResponses([
            ("@@character_set_server", .single(
                columns: ["version", "server_charset", "server_collation", "sql_mode", "client_charset", "connection_collation"],
                rows: [["8.0.36", "utf8mb4", "utf8mb4_0900_ai_ci", "", "utf8mb4", "utf8mb4_general_ci"]]
            )),
        ])
        let repository = MetaRepository(session: fake, clock: MutableClock())
        let info = try await repository.serverInfo()
        XCTAssertEqual(info.version, "8.0.36")
    }

    func testNoteExecutedSQLInvalidatesTableCache() async throws {
        let fake = FakeMySQLSession()
        await fake.setResponses([
            ("TABLE_COLLATION", objectsResponse()),
            ("information_schema.COLUMNS", .single(columns: ["COLUMN_NAME"], rows: [])),
            ("information_schema.STATISTICS", .single(columns: ["INDEX_NAME"], rows: [])),
            ("information_schema.KEY_COLUMN_USAGE", .single(columns: ["CONSTRAINT_NAME"], rows: [])),
            ("information_schema.TRIGGERS", .single(columns: ["TRIGGER_NAME"], rows: [])),
            ("SHOW CREATE TABLE", .single(columns: ["Table", "Create Table"], rows: [])),
        ])
        let repository = MetaRepository(session: fake, clock: MutableClock())
        _ = try await repository.objects(database: "app_dev")
        _ = try await repository.structure(database: "app_dev", table: "users")

        let invalidation = await repository.noteExecutedSQL("DROP TABLE app_dev.users", currentDatabase: "app_dev")
        XCTAssertTrue(invalidation.containsDDL)

        _ = try await repository.objects(database: "app_dev")
        let objectsCount = await fake.executedSQL.filter { $0.contains("TABLE_COLLATION") }.count
        XCTAssertEqual(objectsCount, 2)

        _ = try await repository.structure(database: "app_dev", table: "users")
        let structureCount = await fake.executedSQL.filter { $0.contains("information_schema.COLUMNS") }.count
        XCTAssertEqual(structureCount, 2)
    }

    func testDDLInvalidatesWholeDatabaseWhenUnresolved() async throws {
        let fake = FakeMySQLSession()
        await fake.setResponses([("TABLE_COLLATION", objectsResponse())])
        let repository = MetaRepository(session: fake, clock: MutableClock())
        _ = try await repository.objects(database: "app_dev")
        await repository.noteExecutedSQL("CREATE FUNCTION f() RETURNS INT RETURN 1", currentDatabase: "app_dev")
        _ = try await repository.objects(database: "app_dev")
        let count = await fake.executedSQL.filter { $0.contains("TABLE_COLLATION") }.count
        XCTAssertEqual(count, 2)
    }

    func testQueryLogRecordsMetaTag() async throws {
        let fake = FakeMySQLSession()
        await fake.setResponses([("SHOW DATABASES", databasesResponse())])
        let recorder = LogRecorder()
        let repository = MetaRepository(session: fake, clock: MutableClock()) { record in
            recorder.record(record)
        }
        _ = try await repository.allDatabases()
        XCTAssertEqual(recorder.records.first?.tag, .meta)
    }
}

// MARK: - 日志记录器

/// 线程安全的记录器（`MetaRepository` 的 log 闭包是 `@Sendable`）。
private final class LogRecorder: Sendable {
    private let storage = Mutex<[QueryLogRecord]>([])

    var records: [QueryLogRecord] { storage.withLock { $0 } }

    func record(_ record: QueryLogRecord) {
        storage.withLock { $0.append(record) }
    }
}
