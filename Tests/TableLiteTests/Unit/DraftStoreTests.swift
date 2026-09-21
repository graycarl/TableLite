import XCTest
@testable import TableLite

/// `DraftStore` 的草稿读写与孤儿清理。见 docs/tech-designs/05-session-management.md §9。
@MainActor
final class DraftStoreTests: XCTestCase {

    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_000_000_000))
        -> (DraftStore, InMemoryFileSystemLocator, InMemoryClock) {
        let fileSystem = InMemoryFileSystemLocator()
        let clock = InMemoryClock(now: now)
        return (DraftStore(fileSystem: fileSystem, clock: clock), fileSystem, clock)
    }

    func testSaveLoadDelete() throws {
        let (store, fileSystem, _) = makeStore()
        let draftID = UUID()

        XCTAssertNil(try store.load(draftID: draftID))

        try store.save("SELECT 1;", draftID: draftID)
        XCTAssertTrue(fileSystem.fileExists(at: store.url(for: draftID)))
        XCTAssertEqual(try store.load(draftID: draftID), "SELECT 1;")

        try store.save("SELECT 2;", draftID: draftID)
        XCTAssertEqual(try store.load(draftID: draftID), "SELECT 2;")

        try store.delete(draftID: draftID)
        XCTAssertFalse(fileSystem.fileExists(at: store.url(for: draftID)))
        XCTAssertNil(try store.load(draftID: draftID))
    }

    func testSavePreservesUTF8AndPermissions() throws {
        let (store, _, _) = makeStore()
        let draftID = UUID()
        let sql = "SELECT '中文', '🌊';"
        try store.save(sql, draftID: draftID)

        XCTAssertEqual(try store.load(draftID: draftID), sql)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url(for: draftID).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRemoveOrphans() throws {
        let (store, fileSystem, clock) = makeStore()
        let referenced = UUID()
        let staleOrphan = UUID()
        let freshOrphan = UUID()

        try store.save("referenced", draftID: referenced)
        try store.save("stale", draftID: staleOrphan)
        try store.save("fresh", draftID: freshOrphan)

        // 把 staleOrphan 的修改时间往回拨 31 天。
        let oldDate = clock.now.addingTimeInterval(-31 * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: store.url(for: staleOrphan).path
        )

        try store.removeOrphans(referenced: [referenced], olderThan: 30)

        XCTAssertTrue(fileSystem.fileExists(at: store.url(for: referenced)), "被引用的草稿不能删")
        XCTAssertFalse(fileSystem.fileExists(at: store.url(for: staleOrphan)), "过期孤儿应被删除")
        XCTAssertTrue(fileSystem.fileExists(at: store.url(for: freshOrphan)), "未过期孤儿保留")
    }

    func testRemoveOrphansWithMissingDirectoryIsNoop() throws {
        let (store, _, _) = makeStore()
        XCTAssertNoThrow(try store.removeOrphans(referenced: [], olderThan: 30))
    }
}
