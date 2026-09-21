import XCTest
@testable import TableLite

/// `ConsoleLogStore` 的环形缓冲与落盘行为。见 docs/tech-designs/02-persistence.md §5。
@MainActor
final class ConsoleLogStoreTests: XCTestCase {

    private func entry(sql: String,
                       category: ConsoleLogStore.Category = .data,
                       timestamp: Date = Date(timeIntervalSince1970: 0)) -> ConsoleLogStore.Entry {
        ConsoleLogStore.Entry(timestamp: timestamp, category: category, sql: sql)
    }

    func testCapacityTrimsOldest() {
        let store = ConsoleLogStore(capacity: 3, clock: InMemoryClock())
        for index in 0..<5 {
            store.append(entry(sql: "stmt\(index)"))
        }
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.sql), ["stmt2", "stmt3", "stmt4"])
        XCTAssertEqual(store.entries.map(\.id), [3, 4, 5])
    }

    func testAppendAssignsIDs() {
        let store = ConsoleLogStore(capacity: 10, clock: InMemoryClock())
        store.append(entry(sql: "a"))
        store.append(entry(sql: "b"))
        XCTAssertEqual(store.entries.map(\.id), [1, 2])
    }

    func testClear() {
        let store = ConsoleLogStore(capacity: 10, clock: InMemoryClock())
        store.append(entry(sql: "a"))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.textDump, "")
    }

    func testTextDump() {
        let clock = InMemoryClock(now: Date(timeIntervalSince1970: 0))
        let store = ConsoleLogStore(capacity: 10, clock: clock)
        store.append(ConsoleLogStore.Entry(
            timestamp: clock.now,
            category: .data,
            database: "shop",
            sql: "SELECT 1",
            elapsed: .milliseconds(12),
            rowCount: 1
        ))
        store.append(ConsoleLogStore.Entry(
            timestamp: clock.now,
            category: .meta,
            sql: "SHOW DATABASES",
            elapsed: .milliseconds(3),
            errorCode: 1045,
            errorMessage: "Access denied"
        ))

        let dump = store.textDump
        XCTAssertTrue(dump.contains("[data]"), dump)
        XCTAssertTrue(dump.contains("[meta]"), dump)
        XCTAssertTrue(dump.contains("(shop)"), dump)
        XCTAssertTrue(dump.contains("12.0ms"), dump)
        XCTAssertTrue(dump.contains("SELECT 1"), dump)
        XCTAssertTrue(dump.contains("→ 1 行"), dump)
        XCTAssertTrue(dump.contains("错误 1045"), dump)
        XCTAssertTrue(dump.contains("Access denied"), dump)
        XCTAssertEqual(dump.split(separator: "\n").count, 2)
    }

    func testFlushToDiskWritesTodayFile() throws {
        let fileSystem = InMemoryFileSystemLocator()
        let clock = InMemoryClock(now: Date(timeIntervalSince1970: 0))
        let store = ConsoleLogStore(capacity: 10, clock: clock, fileSystem: fileSystem, writeToFile: true)
        store.append(entry(sql: "SELECT 1"))

        try store.flushToDisk()

        let logsDirectory = try XCTUnwrap(store.logsDirectory)
        let files = try fileSystem.contentsOfDirectory(at: logsDirectory)
        XCTAssertEqual(files.count, 1)
        let text = String(decoding: try fileSystem.readData(at: files[0]), as: UTF8.self)
        XCTAssertTrue(text.contains("SELECT 1"), text)

        // 再次 flush 不应重复写入旧行。
        try store.flushToDisk()
        let textAgain = String(decoding: try fileSystem.readData(at: files[0]), as: UTF8.self)
        XCTAssertEqual(text, textAgain)
    }

    func testFlushToDiskPrunesFilesOlderThanSevenDays() throws {
        let fileSystem = InMemoryFileSystemLocator()
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let clock = InMemoryClock(now: now)
        let store = ConsoleLogStore(capacity: 10, clock: clock, fileSystem: fileSystem, writeToFile: true)
        store.append(entry(sql: "SELECT 1"))
        try store.flushToDisk()

        let logsDirectory = try XCTUnwrap(store.logsDirectory)
        let current = try XCTUnwrap(try fileSystem.contentsOfDirectory(at: logsDirectory).first)

        // 造一个 8 天前的旧日志文件。
        let staleURL = logsDirectory.appendingPathComponent("console-2001-09-01.log")
        try fileSystem.writeAtomically(Data("old\n".utf8), to: staleURL, permissions: 0o600)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: staleURL.path
        )
        // 当前文件保持“刚写入”的时间。
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: current.path)

        try store.flushToDisk()

        XCTAssertFalse(fileSystem.fileExists(at: staleURL))
        XCTAssertTrue(fileSystem.fileExists(at: current))
    }
}
