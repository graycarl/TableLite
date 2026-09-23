import XCTest
@testable import TableLite

/// 会话恢复 `session.json`：原子写、向前兼容、版本备份、草稿引用。
final class SessionStateStoreTests: XCTestCase {

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

    private func sampleState() -> SessionStateFile {
        let connectionID = UUID()
        let draftID = UUID()
        let tabID = UUID()
        var tab = SessionTabState(
            id: tabID,
            kind: .query,
            title: "查询 1",
            queryDraftID: draftID
        )
        tab.sort = [SortOrder(column: "id", direction: .descending)]
        tab.hiddenColumns = ["payload"]
        tab.rowLimit = RowLimitState(limit: 1000)
        tab.filter = FilterState(rawWhere: "id > 10", isRawMode: true, isVisible: true)

        let session = SessionState(
            connectionID: connectionID,
            selectedDatabase: "app_dev",
            activeTabID: tabID,
            tabs: [tab]
        )
        return SessionStateFile(activeConnectionID: connectionID, sessions: [session])
    }

    func testSaveLoadRoundTrip() async throws {
        let store = SessionStateStore(layout: layout)
        let state = sampleState()
        try await store.save(state)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, state)
    }

    func testMissingFileReturnsNil() async throws {
        let loaded = try await SessionStateStore(layout: layout).load()
        XCTAssertNil(loaded)
    }

    func testClearRemovesFile() async throws {
        let store = SessionStateStore(layout: layout)
        try await store.save(sampleState())
        try await store.clear()
        let loaded = try await store.load()
        XCTAssertNil(loaded)
    }

    func testUnknownVersionIsBackedUp() async throws {
        try AtomicFileWriter.write(#"{"schemaVersion": 9, "sessions": []}"#, to: layout.sessionFile)

        let store = SessionStateStore(layout: layout)
        let loaded = try await store.load()
        XCTAssertNil(loaded)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.sessionFile.appendingPathExtension("bak-9").path
        ))
        let notices = await store.takeNotices()
        XCTAssertFalse(notices.isEmpty)
    }

    func testCorruptFileIsBackedUp() async throws {
        try AtomicFileWriter.write("不是 JSON", to: layout.sessionFile)

        let store = SessionStateStore(layout: layout)
        let loaded = try await store.load()
        XCTAssertNil(loaded)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.sessionFile.appendingPathExtension("bak-unknown").path
        ))
    }

    func testForwardCompatibleDecodingFillsDefaults() throws {
        // 缺少 schemaVersion / title / sort 等字段，应取默认值。
        let json = """
        {
          "sessions": [
            {
              "connectionID": "\(UUID().uuidString)",
              "tabs": [ { "kind": "tableData", "objectName": "users" } ]
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(SessionStateFile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, SessionStateFile.currentSchemaVersion)
        XCTAssertEqual(decoded.sessions.count, 1)
        let tab = try XCTUnwrap(decoded.sessions.first?.tabs.first)
        XCTAssertEqual(tab.kind, .tableData)
        XCTAssertEqual(tab.title, "")
        XCTAssertTrue(tab.sort.isEmpty)
        XCTAssertTrue(tab.hiddenColumns.isEmpty)
    }

    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {
          "schemaVersion": 1,
          "futureField": { "nested": true },
          "sessions": []
        }
        """
        XCTAssertNoThrow(try JSONDecoder().decode(SessionStateFile.self, from: Data(json.utf8)))
    }

    func testReferencedDraftIDs() async throws {
        let state = sampleState()
        let expected = Set(state.sessions.flatMap { $0.tabs.compactMap(\.queryDraftID) })

        let store = SessionStateStore(layout: layout)
        try await store.save(state)
        let referenced = try await store.referencedDraftIDs()
        XCTAssertEqual(referenced, expected)
    }
}
