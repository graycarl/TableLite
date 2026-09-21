import XCTest
@testable import TableLite

/// `ConnectionStore` 的持久化行为。见 docs/tech-designs/02-persistence.md §2 §9。
@MainActor
final class ConnectionStoreTests: XCTestCase {

    private func makeStore() -> (ConnectionStore, InMemoryFileSystemLocator) {
        let fileSystem = InMemoryFileSystemLocator()
        return (ConnectionStore(fileSystem: fileSystem), fileSystem)
    }

    private func sampleConnection() -> Connection {
        var connection = Connection()
        connection.name = "本地开发"
        connection.color = .blue
        connection.readOnly = true
        connection.mysql.host = "db.example.com"
        connection.mysql.port = 3307
        connection.mysql.user = "dev"
        connection.mysql.database = "shop"
        connection.ssh.enabled = true
        connection.ssh.host = "bastion"
        return connection
    }

    func testRoundTrip() throws {
        let (store, fileSystem) = makeStore()
        let connection = sampleConnection()
        try store.add(connection)

        let reloaded = ConnectionStore(fileSystem: fileSystem)
        try reloaded.load()

        XCTAssertEqual(reloaded.connections.count, 1)
        let stored = try XCTUnwrap(reloaded.connection(id: connection.id))
        XCTAssertEqual(stored.id, connection.id)
        XCTAssertEqual(stored.name, connection.name)
        XCTAssertEqual(stored.color, connection.color)
        XCTAssertEqual(stored.readOnly, connection.readOnly)
        XCTAssertEqual(stored.mysql, connection.mysql)
        XCTAssertEqual(stored.ssh, connection.ssh)
        // 时间戳经 JSON 往返可能有浮点误差，只比较到毫秒。
        XCTAssertEqual(stored.createdAt.timeIntervalSince1970,
                       connection.createdAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(stored.updatedAt.timeIntervalSince1970,
                       connection.updatedAt.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testAddUpdateRemove() throws {
        let (store, _) = makeStore()
        var connection = sampleConnection()
        try store.add(connection)
        XCTAssertEqual(store.connections.count, 1)

        connection.name = "改名后"
        try store.update(connection)
        XCTAssertEqual(store.connection(id: connection.id)?.name, "改名后")

        try store.remove(id: connection.id)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertNil(store.connection(id: connection.id))
    }

    func testFileContainsSchemaVersion() throws {
        let (store, fileSystem) = makeStore()
        try store.add(sampleConnection())

        let data = try fileSystem.readData(at: store.fileURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual((json["connections"] as? [Any])?.count, 1)
    }

    func testFilePermissionsAre0600() throws {
        let (store, _) = makeStore()
        try store.add(sampleConnection())

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testPasswordFieldsAreDropped() throws {
        let fileSystem = InMemoryFileSystemLocator()
        let url = fileSystem.applicationSupportDirectory.appendingPathComponent("connections.json")
        let id = UUID().uuidString
        let json = """
        {"schemaVersion":1,"connections":[{"id":"\(id)","name":"x",\
        "mysql":{"host":"h","password":"secret-db"},\
        "ssh":{"passphrase":"secret-ssh"}}]}
        """
        try fileSystem.writeAtomically(Data(json.utf8), to: url, permissions: 0o600)

        let store = ConnectionStore(fileSystem: fileSystem)
        try store.load()

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connections.first?.mysql.host, "h")

        // 再次保存后，密文字段不得出现在文件里。
        try store.save()
        let saved = String(decoding: try fileSystem.readData(at: url), as: UTF8.self)
        XCTAssertFalse(saved.contains("password"))
        XCTAssertFalse(saved.contains("passphrase"))
        XCTAssertFalse(saved.contains("secret-db"))
        XCTAssertFalse(saved.contains("secret-ssh"))
    }

    func testMissingFieldsUseDefaults() throws {
        let fileSystem = InMemoryFileSystemLocator()
        let url = fileSystem.applicationSupportDirectory.appendingPathComponent("connections.json")
        let id = UUID().uuidString
        let json = #"{"schemaVersion":1,"connections":[{"id":"\#(id)"}]}"#
        try fileSystem.writeAtomically(Data(json.utf8), to: url, permissions: 0o600)

        let store = ConnectionStore(fileSystem: fileSystem)
        try store.load()

        let connection = try XCTUnwrap(store.connections.first)
        XCTAssertEqual(connection.id.uuidString, id)
        XCTAssertEqual(connection.name, "")
        XCTAssertEqual(connection.color, .none)
        XCTAssertFalse(connection.readOnly)
        XCTAssertEqual(connection.mysql.host, "127.0.0.1")
        XCTAssertEqual(connection.mysql.port, 3306)
        XCTAssertFalse(connection.ssh.enabled)
    }

    func testUnknownVersionIsBackedUpAndRebuilt() throws {
        let fileSystem = InMemoryFileSystemLocator()
        let url = fileSystem.applicationSupportDirectory.appendingPathComponent("connections.json")
        let json = #"{"schemaVersion":2,"connections":[{"name":"未来版本"}]}"#
        try fileSystem.writeAtomically(Data(json.utf8), to: url, permissions: 0o600)

        let store = ConnectionStore(fileSystem: fileSystem)
        XCTAssertThrowsError(try store.load()) { error in
            guard case ConnectionStoreError.unsupportedVersion(let backup) = error else {
                return XCTFail("应当是 unsupportedVersion，实际为 \(error)")
            }
            XCTAssertEqual(backup.lastPathComponent, "connections.json.bak-2")
        }

        // 原文件已备份，且内容原样保留。
        let backupURL = fileSystem.applicationSupportDirectory
            .appendingPathComponent("connections.json.bak-2")
        XCTAssertTrue(fileSystem.fileExists(at: backupURL))
        let backupText = String(decoding: try fileSystem.readData(at: backupURL), as: UTF8.self)
        XCTAssertTrue(backupText.contains("未来版本"))

        // 已按默认值重建。
        XCTAssertTrue(store.connections.isEmpty)
        let rebuilt = try fileSystem.readData(at: url)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: rebuilt) as? [String: Any])
        XCTAssertEqual(dict["schemaVersion"] as? Int, 1)
    }

    func testLoadMissingFileYieldsEmptyList() throws {
        let (store, _) = makeStore()
        try store.load()
        XCTAssertTrue(store.connections.isEmpty)
    }
}
