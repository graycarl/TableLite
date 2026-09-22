import XCTest
@testable import TableLite

/// 原子写入、权限、备份。
final class AtomicFileWriterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteAtomicTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testWriteAndReadText() throws {
        let file = directory.appendingPathComponent("a/connections.json")
        try AtomicFileWriter.write("你好", to: file)
        XCTAssertEqual(try AtomicFileWriter.readText(file), "你好")
    }

    func testReadMissingReturnsNil() throws {
        let file = directory.appendingPathComponent("missing.json")
        XCTAssertNil(try AtomicFileWriter.read(file))
        XCTAssertNil(try AtomicFileWriter.readText(file))
    }

    func testOverwriteReplacesContent() throws {
        let file = directory.appendingPathComponent("a/data.txt")
        try AtomicFileWriter.write("第一版", to: file)
        try AtomicFileWriter.write("第二版", to: file)
        XCTAssertEqual(try AtomicFileWriter.readText(file), "第二版")
    }

    func testFilePermissionsAre0600() throws {
        let file = directory.appendingPathComponent("secret.json")
        try AtomicFileWriter.write("x", to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testDirectoryPermissionsAre0700() throws {
        let subdirectory = directory.appendingPathComponent("nested/deep", isDirectory: true)
        try AtomicFileWriter.ensureDirectory(subdirectory)
        let attributes = try FileManager.default.attributesOfItem(atPath: subdirectory.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o700)
    }

    func testRemoveIsIdempotent() throws {
        let file = directory.appendingPathComponent("a/data.txt")
        try AtomicFileWriter.write("x", to: file)
        try AtomicFileWriter.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // 再删一次不抛错
        XCTAssertNoThrow(try AtomicFileWriter.remove(file))
    }

    func testBackupCreatesVersionedCopy() throws {
        let file = directory.appendingPathComponent("connections.json")
        try AtomicFileWriter.write("原始内容", to: file)

        let backup = try AtomicFileWriter.backup(file, suffix: "2")
        XCTAssertEqual(backup.lastPathComponent, "connections.json.bak-2")
        XCTAssertEqual(try AtomicFileWriter.readText(backup), "原始内容")
        // 原文件仍在
        XCTAssertEqual(try AtomicFileWriter.readText(file), "原始内容")
    }

    func testEnsureDirectoryRejectsFile() throws {
        let file = directory.appendingPathComponent("plain.txt")
        try AtomicFileWriter.write("x", to: file)
        XCTAssertThrowsError(try AtomicFileWriter.ensureDirectory(file))
    }

    func testDraftFileNamingRoundTrip() {
        let id = UUID()
        let layout = AppStorageLayout(rootDirectory: directory)
        let name = layout.draftFile(id: id).lastPathComponent
        XCTAssertEqual(AppStorageLayout.draftID(fromFileName: name), id)
        XCTAssertNil(AppStorageLayout.draftID(fromFileName: "notes.sql"))
        XCTAssertNil(AppStorageLayout.draftID(fromFileName: "draft-abc.txt"))
    }

    func testTemporaryFileSystemLocatorCreatesRoot() throws {
        let locator = TemporaryFileSystemLocator.unique()
        let root = try locator.storageRoot()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        try? FileManager.default.removeItem(at: root)
    }
}
