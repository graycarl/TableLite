import XCTest
@testable import TableLite

/// `HistoryRepository` 集成测试：用真实 SQLite 文件 + `InMemoryFileSystemLocator`，不需要 MySQL。
///
/// 覆盖写入 / 查询 / 过滤 / 删除 / prune / clear。见 docs/tech-designs/02-persistence.md §4。
@MainActor
final class HistoryRepositoryTests: XCTestCase {

    private var root: URL!
    private var fileSystem: InMemoryFileSystemLocator!
    private var repository: HistoryRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteHistoryTests-\(UUID().uuidString)", isDirectory: true)
        fileSystem = InMemoryFileSystemLocator(root: root)
        repository = HistoryRepository(fileSystem: fileSystem, clock: LiveClock())
    }

    override func tearDown() async throws {
        repository = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 辅助

    private func makeEntry(connection: UUID,
                           sql: String,
                           succeeded: Bool = true,
                           executedAt: Date,
                           database: String? = "app_dev") -> HistoryRepository.NewEntry {
        HistoryRepository.NewEntry(
            connectionID: connection,
            database: database,
            sql: sql,
            succeeded: succeeded,
            elapsed: .milliseconds(12),
            rowCount: succeeded ? 3 : nil,
            affectedRows: succeeded ? nil : 0,
            errorCode: succeeded ? nil : 1064,
            executedAt: executedAt
        )
    }

    private var base: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    // MARK: 写入 / 读回

    func testRecordAndRecentRoundTrip() throws {
        let connection = UUID()
        try repository.record(makeEntry(connection: connection, sql: "SELECT 1", executedAt: base))
        try repository.record(makeEntry(connection: connection, sql: "SELEC 1",
                                        succeeded: false, executedAt: base.addingTimeInterval(1)))

        XCTAssertEqual(try repository.count(), 2)

        let recent = try repository.recent(connectionID: nil, search: nil, limit: 10)
        XCTAssertEqual(recent.map(\.sql), ["SELEC 1", "SELECT 1"], "按执行时间倒序")

        let ok = recent[1]
        XCTAssertEqual(ok.connectionID, connection)
        XCTAssertEqual(ok.database, "app_dev")
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.rowCount, 3)
        XCTAssertNil(ok.errorCode)

        let failed = recent[0]
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.errorCode, 1064)
        XCTAssertEqual(failed.affectedRows, 0)
    }

    // MARK: 过滤

    func testRecentFiltersByConnectionAndSearch() throws {
        let a = UUID()
        let b = UUID()
        try repository.record(makeEntry(connection: a, sql: "SELECT * FROM users", executedAt: base))
        try repository.record(makeEntry(connection: a, sql: "SELECT * FROM orders",
                                        executedAt: base.addingTimeInterval(1)))
        try repository.record(makeEntry(connection: b, sql: "SELECT * FROM products",
                                        executedAt: base.addingTimeInterval(2)))

        let onlyA = try repository.recent(connectionID: a, search: nil, limit: 10)
        XCTAssertEqual(onlyA.map(\.sql), ["SELECT * FROM orders", "SELECT * FROM users"])

        let users = try repository.recent(connectionID: nil, search: "users", limit: 10)
        XCTAssertEqual(users.map(\.sql), ["SELECT * FROM users"])

        let limited = try repository.recent(connectionID: nil, search: nil, limit: 2)
        XCTAssertEqual(limited.count, 2)
    }

    // MARK: 删除

    func testDeleteByID() throws {
        let connection = UUID()
        try repository.record(makeEntry(connection: connection, sql: "SELECT 1", executedAt: base))
        try repository.record(makeEntry(connection: connection, sql: "SELECT 2",
                                        executedAt: base.addingTimeInterval(1)))
        let all = try repository.recent(connectionID: nil, search: nil, limit: 10)
        let target = try XCTUnwrap(all.first)

        try repository.delete(id: target.id)
        XCTAssertEqual(try repository.count(), 1)
        XCTAssertEqual(try repository.recent(connectionID: nil, search: nil, limit: 10).map(\.sql), ["SELECT 1"])
    }

    // MARK: prune

    func testPruneKeepsMostRecent() throws {
        let connection = UUID()
        for index in 0..<10 {
            try repository.record(makeEntry(connection: connection,
                                            sql: "SELECT \(index)",
                                            executedAt: base.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(try repository.count(), 10)

        try repository.prune(keeping: 3)
        XCTAssertEqual(try repository.count(), 3)
        XCTAssertEqual(try repository.recent(connectionID: nil, search: nil, limit: 10).map(\.sql),
                       ["SELECT 9", "SELECT 8", "SELECT 7"])

        // 上限 0 → 清空；负数 → 不做任何事
        try repository.prune(keeping: 0)
        XCTAssertEqual(try repository.count(), 0)
        try repository.record(makeEntry(connection: connection, sql: "SELECT x", executedAt: base))
        try repository.prune(keeping: -5)
        XCTAssertEqual(try repository.count(), 1)
    }

    // MARK: clear

    func testEntriesPersistAcrossReopen() throws {
        let connection = UUID()
        try repository.record(makeEntry(connection: connection, sql: "SELECT 42", executedAt: base))

        // 关闭后重新打开同一个文件，数据应当还在（真实 SQLite WAL）。
        repository = nil
        repository = HistoryRepository(fileSystem: fileSystem, clock: LiveClock())
        XCTAssertEqual(try repository.count(), 1)
        XCTAssertEqual(try repository.recent(connectionID: nil, search: nil, limit: 10).first?.sql, "SELECT 42")
    }

    func testClearByConnectionAndAll() throws {
        let a = UUID()
        let b = UUID()
        try repository.record(makeEntry(connection: a, sql: "A1", executedAt: base))
        try repository.record(makeEntry(connection: b, sql: "B1", executedAt: base.addingTimeInterval(1)))

        try repository.clear(connectionID: a)
        XCTAssertEqual(try repository.recent(connectionID: nil, search: nil, limit: 10).map(\.sql), ["B1"])

        try repository.clear(connectionID: nil)
        XCTAssertEqual(try repository.count(), 0)
    }
}
