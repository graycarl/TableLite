import XCTest
@testable import TableLite

/// 偏好持久化层：默认值、写回、枚举回落、重置。
@MainActor
final class PreferencesStoreTests: XCTestCase {

    func testReadsDefaultsWhenEmpty() {
        let store = PreferencesStore(store: InMemoryKeyValueStore())
        XCTAssertTrue(store.bool(.restoreLastWorkspace))
        XCTAssertEqual(store.integer(.gridPageSize), 300)
        XCTAssertEqual(store.double(.gridInspectorWidth), 320)
        XCTAssertEqual(store.string(.gridNullDisplayText), "NULL")
        XCTAssertEqual(store.choice(.csvDelimiter, CSVExportDelimiter.self, fallback: .comma), .comma)
    }

    func testRoundTrip() {
        let backing = InMemoryKeyValueStore()
        let store = PreferencesStore(store: backing)
        store.set(1000, for: .gridPageSize)
        store.set(false, for: .restoreLastWorkspace)
        store.setChoice(CSVExportDelimiter.semicolon, for: .csvDelimiter)

        let reloaded = PreferencesStore(store: backing)
        XCTAssertEqual(reloaded.integer(.gridPageSize), 1000)
        XCTAssertFalse(reloaded.bool(.restoreLastWorkspace))
        XCTAssertEqual(reloaded.choice(.csvDelimiter, CSVExportDelimiter.self, fallback: .comma), .semicolon)
    }

    func testUnknownRawValueFallsBackToDefault() {
        let backing = InMemoryKeyValueStore(storage: [
            PreferenceKey.csvLineEnding.rawValue: "不认识的换行符",
        ])
        let store = PreferencesStore(store: backing)
        XCTAssertEqual(store.choice(.csvLineEnding, CSVLineEnding.self, fallback: .crlf), .lf)
    }

    func testWrongTypeFallsBackToDefault() {
        let backing = InMemoryKeyValueStore(storage: [
            PreferenceKey.gridPageSize.rawValue: "不是数字",
        ])
        let store = PreferencesStore(store: backing)
        XCTAssertEqual(store.integer(.gridPageSize), 300)
    }

    func testResetAll() {
        let backing = InMemoryKeyValueStore()
        let store = PreferencesStore(store: backing)
        store.set(1000, for: .gridPageSize)
        store.resetAll()
        XCTAssertEqual(store.integer(.gridPageSize), 300)
    }
}
