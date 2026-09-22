import XCTest
@testable import TableLite

/// 连接元数据 JSON：原子写、向前兼容、密码字段剔除、版本备份、连带清理钥匙串。
final class ConnectionStoreTests: XCTestCase {

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

    private func makeStore(credentials: CredentialStore = InMemoryCredentialStore()) -> ConnectionStore {
        ConnectionStore(layout: layout, credentials: credentials)
    }

    func testSaveAndLoadRoundTrip() async throws {
        let store = makeStore()
        let connection = StoreTestSupport.connection(name: "生产")
        try await store.save([connection])

        let result = try await store.load()
        XCTAssertEqual(result.connections, [connection])
        XCTAssertTrue(result.notices.isEmpty)
        let loaded = try await store.connection(id: connection.id)
        XCTAssertEqual(loaded, connection)
    }

    func testUpsertAddsThenUpdates() async throws {
        let store = makeStore()
        var connection = StoreTestSupport.connection(name: "本地")
        _ = try await store.upsert(connection)

        connection.name = "本地改名"
        _ = try await store.upsert(connection)

        let list = try await store.allConnections()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "本地改名")
    }

    func testFileContainsSchemaVersionAndNoSecrets() async throws {
        let store = makeStore()
        try await store.save([StoreTestSupport.connection()])

        let text = try XCTUnwrap(try AtomicFileWriter.readText(layout.connectionsFile))
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        XCTAssertFalse(text.lowercased().contains("password"))
        XCTAssertFalse(text.lowercased().contains("passphrase"))
    }

    func testLoadDropsSecretFieldsAndReportsNotice() async throws {
        // 手工构造一份混入 password 字段的 JSON。
        let connection = StoreTestSupport.connection()
        let encoded = try JSONEncoder().encode(ConnectionMetadataFile(connections: [connection]))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var connections = try XCTUnwrap(object["connections"] as? [[String: Any]])
        connections[0]["password"] = "明文密码"
        connections[0]["passphrase"] = "明文口令"
        object["connections"] = connections
        let polluted = try JSONSerialization.data(withJSONObject: object)
        try AtomicFileWriter.write(polluted, to: layout.connectionsFile)

        let result = try await makeStore().load()
        XCTAssertEqual(result.connections.count, 1)
        XCTAssertEqual(result.connections.first?.id, connection.id)
        XCTAssertFalse(result.notices.isEmpty)
        XCTAssertTrue(result.notices.joined().contains("password"))
    }

    func testUnknownVersionIsBackedUpAndRebuilt() async throws {
        try AtomicFileWriter.write(#"{"schemaVersion": 99, "connections": []}"#, to: layout.connectionsFile)

        let result = try await makeStore().load()
        XCTAssertTrue(result.connections.isEmpty)
        XCTAssertFalse(result.notices.isEmpty)

        let backup = layout.connectionsFile.appendingPathExtension("bak-99")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testCorruptFileIsBackedUpWithUnknownSuffix() async throws {
        try AtomicFileWriter.write("这不是 JSON", to: layout.connectionsFile)

        let result = try await makeStore().load()
        XCTAssertTrue(result.connections.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.connectionsFile.appendingPathExtension("bak-unknown").path
        ))
    }

    func testMissingFileYieldsEmptyList() async throws {
        let result = try await makeStore().load()
        XCTAssertTrue(result.connections.isEmpty)
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testDeleteCleansCredentials() async throws {
        let credentials = InMemoryCredentialStore()
        let store = makeStore(credentials: credentials)
        let connection = StoreTestSupport.connection()
        try await store.upsert(connection)
        try credentials.setPassword("db", for: connection.id, kind: .mysqlPassword)
        try credentials.setPassword("ssh", for: connection.id, kind: .sshPassword)
        try credentials.setPassword("key", for: connection.id, kind: .sshPassphrase)
        XCTAssertEqual(credentials.count, 3)

        try await store.delete(id: connection.id)
        XCTAssertEqual(credentials.count, 0)
        let remaining = try await store.allConnections()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testNoticesPersistUntilTaken() async throws {
        try AtomicFileWriter.write(#"{"schemaVersion": 99, "connections": []}"#, to: layout.connectionsFile)
        let store = makeStore()

        let first = try await store.load()
        XCTAssertFalse(first.notices.isEmpty)
        // 中间调用不会吃掉提示
        let second = try await store.load()
        XCTAssertFalse(second.notices.isEmpty)

        let taken = await store.takeNotices()
        XCTAssertFalse(taken.isEmpty)
        let third = try await store.load()
        XCTAssertTrue(third.notices.isEmpty)
    }

    func testInvalidateCacheRereadsFile() async throws {
        let store = makeStore()
        try await store.save([StoreTestSupport.connection(name: "A")])
        _ = try await store.load()

        // 外部改文件后，失效缓存应读到新内容。
        try await store.save([StoreTestSupport.connection(name: "B")])
        await store.invalidateCache()
        let list = try await store.allConnections()
        XCTAssertEqual(list.map(\.name), ["B"])
    }
}
