import XCTest
@testable import TableLite

/// 查询草稿：读写删、孤儿清理（超过 30 天且未被 session.json 引用）。
final class QueryDraftStoreTests: XCTestCase {

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

    func testWriteReadDelete() async throws {
        let store = QueryDraftStore(layout: layout)
        let id = UUID()

        let missing = try await store.read(id: id)
        XCTAssertNil(missing)

        try await store.write("SELECT 1;", id: id)
        let content = try await store.read(id: id)
        XCTAssertEqual(content, "SELECT 1;")
        let ids = try await store.allDraftIDs()
        XCTAssertEqual(ids, [id])

        try await store.delete(id: id)
        let deleted = try await store.read(id: id)
        XCTAssertNil(deleted)
    }

    func testCleanupRemovesOnlyOldUnreferencedDrafts() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = QueryDraftStore(layout: layout, clock: clock, retentionDays: 30)

        let referencedOld = UUID()
        let orphanOld = UUID()
        let orphanNew = UUID()
        try await store.write("a", id: referencedOld)
        try await store.write("b", id: orphanOld)
        try await store.write("c", id: orphanNew)

        // 把两份草稿的修改时间改到 40 天前。
        let oldDate = clock.now.addingTimeInterval(-40 * 24 * 3600)
        for id in [referencedOld, orphanOld] {
            let url = layout.draftFile(id: id)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
        }

        let removed = try await store.cleanupOrphans(referencedIDs: [referencedOld])
        XCTAssertEqual(Set(removed), [orphanOld])

        let referencedContent = try await store.read(id: referencedOld)
        XCTAssertEqual(referencedContent, "a")
        let orphanNewContent = try await store.read(id: orphanNew)
        XCTAssertEqual(orphanNewContent, "c")
    }

    func testCleanupFromSessionState() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = QueryDraftStore(layout: layout, clock: clock, retentionDays: 30)

        let referenced = UUID()
        let orphan = UUID()
        try await store.write("a", id: referenced)
        try await store.write("b", id: orphan)

        let oldDate = clock.now.addingTimeInterval(-60 * 24 * 3600)
        for id in [referenced, orphan] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: layout.draftFile(id: id).path
            )
        }

        let state = SessionStateFile(sessions: [
            SessionState(connectionID: UUID(), tabs: [
                SessionTabState(kind: .query, queryDraftID: referenced)
            ])
        ])
        let removed = try await store.cleanupOrphans(referencedFrom: state)
        XCTAssertEqual(Set(removed), [orphan])
    }

    func testRemoveAll() async throws {
        let store = QueryDraftStore(layout: layout)
        try await store.write("a", id: UUID())
        try await store.write("b", id: UUID())

        try await store.removeAll()
        let remaining = try await store.allDraftIDs()
        XCTAssertTrue(remaining.isEmpty)
    }
}
