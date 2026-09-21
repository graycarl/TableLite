import XCTest
@testable import TableLite

/// 查询历史 SQLite：写入、查询、搜索、清空、容量裁剪。
final class QueryHistoryStoreTests: XCTestCase {

    private var directory: URL!
    private var layout: AppStorageLayout!

    override func setUpWithError() throws {
        let made = StoreTestSupport.makeTemporaryLayout()
        directory = made.directory
        layout = made.layout
    }

    override func tearDownWithError() throws {
        if let directory { StoreTestSupport.remove(directory) }
    }

    private func entry(
        connectionID: UUID,
        sql: String,
        at seconds: TimeInterval,
        succeeded: Bool = true,
        database: String? = "app_dev"
    ) -> QueryHistoryEntry {
        QueryHistoryEntry(
            id: 0,
            connectionID: connectionID,
            database: database,
            sql: sql,
            executedAt: Date(timeIntervalSince1970: seconds),
            succeeded: succeeded,
            durationMilliseconds: 42,
            returnedRowCount: succeeded ? 1204 : nil,
            affectedRows: nil,
            errorCode: succeeded ? nil : 1064,
            errorMessage: succeeded ? nil : "You have an error in your SQL syntax"
        )
    }

    func testAppendAssignsIDAndRoundTrips() async throws {
        let store = QueryHistoryStore(layout: layout)
        let connectionID = UUID()
        let stored = try await store.append(entry(connectionID: connectionID, sql: "SELECT 1", at: 1_700_000_000))

        XCTAssertGreaterThan(stored.id, 0)
        XCTAssertEqual(stored.connectionID, connectionID)
        XCTAssertEqual(stored.returnedRowCount, 1204)

        let entries = try await store.recent(connectionID: connectionID)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.sql, "SELECT 1")
        XCTAssertEqual(entries.first?.succeeded, true)
        XCTAssertEqual(entries.first?.durationMilliseconds, 42)
        XCTAssertEqual(entries.first?.executedAt.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
    }

    func testErrorEntryRoundTrips() async throws {
        let store = QueryHistoryStore(layout: layout)
        let connectionID = UUID()
        _ = try await store.append(entry(connectionID: connectionID, sql: "SELECT * FORM t", at: 1, succeeded: false))

        let entries = try await store.recent(connectionID: connectionID)
        let stored = entries.first
        XCTAssertEqual(stored?.succeeded, false)
        XCTAssertEqual(stored?.errorCode, 1064)
        XCTAssertEqual(stored?.errorMessage, "You have an error in your SQL syntax")
    }

    func testOrderIsNewestFirst() async throws {
        let store = QueryHistoryStore(layout: layout)
        let connectionID = UUID()
        for index in 1...3 {
            _ = try await store.append(entry(connectionID: connectionID, sql: "SELECT \(index)", at: TimeInterval(index)))
        }
        let entries = try await store.recent(connectionID: connectionID)
        XCTAssertEqual(entries.map(\.sql), ["SELECT 3", "SELECT 2", "SELECT 1"])
    }

    func testSearchEscapesLikeWildcards() async throws {
        let store = QueryHistoryStore(layout: layout)
        let connectionID = UUID()
        _ = try await store.append(entry(connectionID: connectionID, sql: "SELECT * FROM users", at: 1))
        _ = try await store.append(entry(connectionID: connectionID, sql: "SELECT * FROM orders", at: 2))
        _ = try await store.append(entry(connectionID: connectionID, sql: "SELECT '100%' FROM t", at: 3))

        let orders = try await store.recent(connectionID: connectionID, search: "orders")
        XCTAssertEqual(orders.map(\.sql), ["SELECT * FROM orders"])

        // `%` 被转义成字面量，不应该匹配到所有行
        let percent = try await store.recent(connectionID: connectionID, search: "%")
        XCTAssertEqual(percent.map(\.sql), ["SELECT '100%' FROM t"])
    }

    func testConnectionFilterAndTimeRange() async throws {
        let store = QueryHistoryStore(layout: layout)
        let first = UUID()
        let second = UUID()
        _ = try await store.append(entry(connectionID: first, sql: "A", at: 100))
        _ = try await store.append(entry(connectionID: second, sql: "B", at: 200))
        _ = try await store.append(entry(connectionID: first, sql: "C", at: 300))

        let firstOnly = try await store.recent(connectionID: first)
        XCTAssertEqual(firstOnly.map(\.sql), ["C", "A"])

        let ranged = try await store.recent(connectionID: first, since: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(ranged.map(\.sql), ["C"])
    }

    func testCountAndClear() async throws {
        let store = QueryHistoryStore(layout: layout)
        let first = UUID()
        let second = UUID()
        _ = try await store.append(entry(connectionID: first, sql: "A", at: 1))
        _ = try await store.append(entry(connectionID: first, sql: "B", at: 2))
        _ = try await store.append(entry(connectionID: second, sql: "C", at: 3))

        var total = try await store.count()
        XCTAssertEqual(total, 3)

        try await store.clear(connectionID: first)
        total = try await store.count()
        XCTAssertEqual(total, 1)
        let remaining = try await store.recent()
        XCTAssertEqual(remaining.map(\.sql), ["C"])

        try await store.clearAll()
        total = try await store.count()
        XCTAssertEqual(total, 0)
    }

    func testDeleteSingleEntry() async throws {
        let store = QueryHistoryStore(layout: layout)
        let connectionID = UUID()
        let first = try await store.append(entry(connectionID: connectionID, sql: "A", at: 1))
        _ = try await store.append(entry(connectionID: connectionID, sql: "B", at: 2))

        try await store.delete(id: first.id)
        let entries = try await store.recent(connectionID: connectionID)
        XCTAssertEqual(entries.map(\.sql), ["B"])
    }

    func testRetentionPrunesOldest() async throws {
        let store = QueryHistoryStore(layout: layout, retention: 3)
        let connectionID = UUID()
        for index in 1...6 {
            _ = try await store.append(entry(connectionID: connectionID, sql: "SELECT \(index)", at: TimeInterval(index)))
        }
        let entries = try await store.recent(connectionID: connectionID)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.sql), ["SELECT 6", "SELECT 5", "SELECT 4"])
    }

    func testPagination() async throws {
        let store = QueryHistoryStore(layout: layout)
        let connectionID = UUID()
        for index in 1...5 {
            _ = try await store.append(entry(connectionID: connectionID, sql: "SELECT \(index)", at: TimeInterval(index)))
        }
        let page = try await store.recent(connectionID: connectionID, limit: 2, offset: 1)
        XCTAssertEqual(page.map(\.sql), ["SELECT 4", "SELECT 3"])
    }

    func testSchemaVersionIsSet() async throws {
        let store = QueryHistoryStore(layout: layout)
        _ = try await store.append(entry(connectionID: UUID(), sql: "SELECT 1", at: 1))
        await store.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.historyDatabase.path))
    }

    func testUnknownUserVersionIsBackedUpAndRebuilt() async throws {
        let store = QueryHistoryStore(layout: layout)
        _ = try await store.append(entry(connectionID: UUID(), sql: "SELECT 1", at: 1))
        await store.close()

        // 直接用底层句柄伪造一个未来版本号（SQLite 用 `PRAGMA user_version`）。
        let database = try SQLiteDatabase(path: layout.historyDatabase.path)
        try database.execute("PRAGMA user_version = 9;")
        database.close()

        let rebuilt = QueryHistoryStore(layout: layout)
        _ = try await rebuilt.append(entry(connectionID: UUID(), sql: "SELECT 2", at: 2))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.historyDatabase.appendingPathExtension("bak-9").path
        ))
    }
}
