import XCTest
@testable import TableLite

/// `credentials.json` 的纯逻辑与文件读写。
///
/// 决策与安全边界见 `02-persistence.md` §3：`0600`、明文、原子写、空串等价删除、
/// 不认识的版本备份后重建；旧 Keychain 条目不读不写（`13-open-questions.md` L45）。
final class FileCredentialStoreTests: XCTestCase {

    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteCredentials-\(UUID().uuidString)", isDirectory: true)
        try AtomicFileWriter.ensureDirectory(directory)
        file = directory.appendingPathComponent("credentials.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> FileCredentialStore {
        FileCredentialStore(file: file)
    }

    // MARK: 文件读写

    func testCredentialsSurviveReopen() throws {
        let id = UUID()
        let store = makeStore()
        try store.setPassword("db-pass", for: id, kind: .mysqlPassword)
        try store.setPassword("ssh-pass", for: id, kind: .sshPassword)

        // 换一个实例重新读，确认真的落盘了（而不是留在内存里）
        let reopened = makeStore()
        XCTAssertEqual(try reopened.password(for: id, kind: .mysqlPassword), "db-pass")
        XCTAssertEqual(try reopened.password(for: id, kind: .sshPassword), "ssh-pass")
        XCTAssertNil(try reopened.password(for: id, kind: .sshPassphrase))
        XCTAssertTrue(try reopened.hasPassword(for: id, kind: .mysqlPassword))
    }

    func testFileIsSixHundredWithSchemaVersion() throws {
        try makeStore().setPassword("x", for: UUID(), kind: .mysqlPassword)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let text = try XCTUnwrap(try AtomicFileWriter.readText(file))
        XCTAssertTrue(text.contains("\"schemaVersion\""), text)
        XCTAssertTrue(text.contains("1"), text)
    }

    func testEmptyPasswordRemovesEntry() throws {
        let id = UUID()
        let store = makeStore()
        try store.setPassword("secret", for: id, kind: .mysqlPassword)
        try store.setPassword("", for: id, kind: .mysqlPassword)

        XCTAssertNil(try store.password(for: id, kind: .mysqlPassword))
        let text = try XCTUnwrap(try AtomicFileWriter.readText(file))
        XCTAssertFalse(text.contains("secret"), text)
    }

    func testDeleteAllOnlyTouchesTargetConnection() throws {
        let first = UUID()
        let second = UUID()
        let store = makeStore()
        try store.setPassword("a", for: first, kind: .mysqlPassword)
        try store.setPassword("b", for: first, kind: .sshPassphrase)
        try store.setPassword("c", for: second, kind: .mysqlPassword)

        try store.deleteAll(for: first)

        XCTAssertNil(try store.password(for: first, kind: .mysqlPassword))
        XCTAssertNil(try store.password(for: first, kind: .sshPassphrase))
        XCTAssertEqual(try store.password(for: second, kind: .mysqlPassword), "c")
    }

    func testMissingFileReadsAsEmpty() throws {
        let store = makeStore()
        XCTAssertNil(try store.password(for: UUID(), kind: .mysqlPassword))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: 版本与损坏（`02-persistence.md` §9）

    func testUnknownVersionIsBackedUpAndRebuilt() throws {
        try AtomicFileWriter.write(
            #"{"schemaVersion": 99, "entries": {"x": {"mysqlPassword": "old"}}}"#,
            to: file
        )

        let store = makeStore()
        XCTAssertNil(try store.password(for: UUID(), kind: .mysqlPassword))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak-99").path))

        let text = try XCTUnwrap(try AtomicFileWriter.readText(file))
        XCTAssertTrue(text.contains("\"schemaVersion\""), text)
        XCTAssertFalse(text.contains("old"), text)
    }

    func testCorruptedFileIsBackedUpAndRebuilt() throws {
        try AtomicFileWriter.write("这不是 JSON", to: file)

        let store = makeStore()
        XCTAssertNil(try store.password(for: UUID(), kind: .mysqlPassword))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak-unknown").path))
    }

    // MARK: 纯逻辑

    func testCredentialFileIsForwardCompatible() throws {
        // 缺 `schemaVersion`、未知字段、未知凭据种类都不该让读取失败
        let data = Data(#"{"unknownField": true, "entries": {"abc": {"mysqlPassword": "p", "futureKind": "z"}}}"#.utf8)
        let decoded = try CredentialFile.decode(from: data)

        XCTAssertEqual(decoded.schemaVersion, CredentialFile.currentSchemaVersion)
        XCTAssertEqual(decoded.entries["abc"]?["mysqlPassword"], "p")
        XCTAssertEqual(decoded.entries["abc"]?["futureKind"], "z")
    }

    func testKindRawValuesAreDistinctJSONKeys() {
        let keys = CredentialKind.allCases.map(\.rawValue)
        XCTAssertEqual(Set(keys).count, CredentialKind.allCases.count)
    }
}
