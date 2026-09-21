import XCTest
@testable import TableLite

/// Console Log：环形缓冲容量、标签过滤、格式化、按天落盘与轮转。
@MainActor
final class ConsoleLogStoreTests: XCTestCase {

    func testRecordAssignsIncreasingIDs() async {
        let store = ConsoleLogStore(capacity: 10, clock: FixedClock(Date(timeIntervalSince1970: 1_700_000_000)))
        let first = await store.record(tag: .data, sql: "SELECT 1")
        let second = await store.record(tag: .meta, sql: "SELECT 2")
        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(second.id, 2)
        XCTAssertEqual(store.allEntries.count, 2)
    }

    func testCapacityDropsOldest() async {
        let store = ConsoleLogStore(capacity: 3, clock: FixedClock(Date(timeIntervalSince1970: 0)))
        for index in 1...5 {
            await store.record(tag: .data, sql: "SELECT \(index)")
        }
        XCTAssertEqual(store.allEntries.count, 3)
        XCTAssertEqual(store.allEntries.map(\.sql), ["SELECT 3", "SELECT 4", "SELECT 5"])
    }

    func testFilterByTag() async {
        let store = ConsoleLogStore(capacity: 10, clock: FixedClock(Date(timeIntervalSince1970: 0)))
        await store.record(tag: .data, sql: "SELECT 1")
        await store.record(tag: .meta, sql: "SELECT 2")
        await store.record(tag: .data, sql: "SELECT 3")

        XCTAssertEqual(store.entries(tag: .data).map(\.sql), ["SELECT 1", "SELECT 3"])
        XCTAssertEqual(store.entries(tag: .meta).map(\.sql), ["SELECT 2"])
    }

    func testSetCapacityTrims() async {
        let store = ConsoleLogStore(capacity: 10, clock: FixedClock(Date(timeIntervalSince1970: 0)))
        for index in 1...5 {
            await store.record(tag: .data, sql: "SELECT \(index)")
        }
        store.setCapacity(2)
        XCTAssertEqual(store.entries.capacity, 2)
        XCTAssertEqual(store.allEntries.map(\.sql), ["SELECT 4", "SELECT 5"])
    }

    func testClear() async {
        let store = ConsoleLogStore(capacity: 10, clock: FixedClock(Date(timeIntervalSince1970: 0)))
        await store.record(tag: .data, sql: "SELECT 1")
        store.clear()
        XCTAssertTrue(store.allEntries.isEmpty)
    }

    func testFormatterTextContainsTagAndSQL() {
        let entry = ConsoleLogEntry(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            tag: .data,
            database: "app_dev",
            sql: "SELECT * FROM users",
            durationMilliseconds: 42,
            returnedRowCount: 1204
        )
        let text = ConsoleLogFormatter.text(for: entry)
        XCTAssertTrue(text.contains("[data]"))
        XCTAssertTrue(text.contains("app_dev"))
        XCTAssertTrue(text.contains("42 ms"))
        XCTAssertTrue(text.contains("1204 行"))
        XCTAssertTrue(text.contains("SELECT * FROM users"))
    }

    func testFormatterKeepsServerErrorMessageVerbatim() {
        let message = "You have an error in your SQL syntax; check the manual"
        let entry = ConsoleLogEntry(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            tag: .data,
            sql: "SELECT * FORM users",
            errorCode: 1064,
            errorMessage: message
        )
        let text = ConsoleLogFormatter.text(for: entry)
        XCTAssertTrue(text.contains("✗ 1064"))
        XCTAssertTrue(text.contains(message))
    }

    func testDayStringAndFileName() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
        XCTAssertEqual(ConsoleLogFormatter.dayString(date, calendar: calendar), "2023-11-14")
        XCTAssertEqual(ConsoleLogFormatter.fileName(day: "2023-11-14"), "console-2023-11-14.log")
        XCTAssertEqual(ConsoleLogFormatter.day(fromFileName: "console-2023-11-14.log"), "2023-11-14")
        XCTAssertNil(ConsoleLogFormatter.day(fromFileName: "random.log"))
    }

    func testFileWriterAppendsAndFlushes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteConsoleLog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let writer = ConsoleLogFileWriter(directory: directory, clock: clock)
        await writer.append("第一行\n")
        await writer.append("第二行\n")
        await writer.flush()

        let file = directory.appendingPathComponent(
            ConsoleLogFormatter.fileName(day: ConsoleLogFormatter.dayString(clock.now))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, "第一行\n第二行\n")
    }

    func testStoreWritesToFileWriter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteConsoleLogStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let writer = ConsoleLogFileWriter(directory: directory, clock: clock)
        let store = ConsoleLogStore(capacity: 10, clock: clock, fileWriter: writer)
        await store.record(tag: .data, database: "app_dev", sql: "SELECT 1")
        await store.record(tag: .meta, sql: "SHOW DATABASES")
        await store.flush()

        let file = directory.appendingPathComponent(
            ConsoleLogFormatter.fileName(day: ConsoleLogFormatter.dayString(clock.now))
        )
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("SELECT 1"))
        XCTAssertTrue(text.contains("SHOW DATABASES"))
    }

    func testFileWriterPrunesOldFiles() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteConsoleLogPrune-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = directory.appendingPathComponent("console-2020-01-01.log")
        let recent = directory.appendingPathComponent("console-2023-11-13.log")
        FileManager.default.createFile(atPath: old.path, contents: Data())
        FileManager.default.createFile(atPath: recent.path, contents: Data())

        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000)) // 2023-11-14
        let writer = ConsoleLogFileWriter(directory: directory, retentionDays: 7, clock: clock)
        await writer.pruneOldFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }
}
