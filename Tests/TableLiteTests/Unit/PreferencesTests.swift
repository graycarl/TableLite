import XCTest
@testable import TableLite

/// 偏好设置：默认值、即时持久化、取值钳制、恢复默认。
@MainActor
final class PreferencesTests: XCTestCase {

    func testDefaultsMatchSpecs() {
        let preferences = Preferences(store: InMemoryKeyValueStore())

        // 通用
        XCTAssertTrue(preferences.restoreLastWorkspace)
        XCTAssertTrue(preferences.restoreLastScript)
        XCTAssertTrue(preferences.idleDisconnect)
        XCTAssertFalse(preferences.reportCrashes)
        // 连接
        XCTAssertEqual(preferences.defaultQueryTimeout, 300)
        XCTAssertTrue(preferences.defaultKeepAlive)
        XCTAssertEqual(preferences.keepAliveInterval, 30)
        XCTAssertEqual(preferences.maxSessions, 8)
        // 表数据
        XCTAssertEqual(preferences.pageSize, 300)
        XCTAssertEqual(preferences.gridFontSize, 13)
        XCTAssertTrue(preferences.alternateRowColors)
        XCTAssertTrue(preferences.autoHideScrollers)
        XCTAssertTrue(preferences.lazyLargeColumns)
        XCTAssertEqual(preferences.lazyLargeColumnThreshold, 4096)
        XCTAssertEqual(preferences.nullDisplayText, "NULL")
        XCTAssertFalse(preferences.tinyintAsCheckbox)
        XCTAssertTrue(preferences.showInspector)
        XCTAssertEqual(preferences.inspectorWidth, 320)
        XCTAssertTrue(preferences.rememberColumnLayout)
        XCTAssertTrue(preferences.rememberFilters)
        // 编辑器
        XCTAssertEqual(preferences.editorFontName, "")
        XCTAssertEqual(preferences.editorFontSize, 13)
        XCTAssertEqual(preferences.indentWidth, 4)
        XCTAssertEqual(preferences.defaultExecutionScope, .currentStatement)
        XCTAssertTrue(preferences.stopOnError)
        XCTAssertTrue(preferences.highlightCurrentStatement)
        XCTAssertTrue(preferences.showLineNumbers)
        XCTAssertTrue(preferences.autoSaveDraft)
        // CSV
        XCTAssertEqual(preferences.csvDelimiter, .comma)
        XCTAssertEqual(preferences.csvLineEnding, .lf)
        XCTAssertTrue(preferences.csvIncludeHeader)
        XCTAssertEqual(preferences.csvEncoding, .utf8)
        XCTAssertEqual(preferences.csvNullRepresentation, .emptyString)
        // 界面
        XCTAssertFalse(preferences.showSystemDatabases)
        XCTAssertEqual(preferences.sidebarWidth, 220)
        XCTAssertEqual(preferences.editorResultSplitRatio, 0.5, accuracy: 0.0001)
        XCTAssertEqual(preferences.language, .chinese)
        // Console Log
        XCTAssertEqual(preferences.consoleLogCapacity, 5000)
        XCTAssertFalse(preferences.consoleLogWriteToFile)
        XCTAssertTrue(preferences.consoleLogScrollToBottom)
    }

    func testChangesPersistImmediately() {
        let store = InMemoryKeyValueStore()
        let preferences = Preferences(store: store)

        preferences.pageSize = 1000
        preferences.nullDisplayText = "(null)"
        preferences.csvDelimiter = .tab
        preferences.defaultExecutionScope = .allStatements
        preferences.lazyLargeColumns = false

        // 底层键值已经写入
        XCTAssertEqual(store.object(forKey: PreferenceKey.gridPageSize.rawValue) as? Int, 1000)
        XCTAssertEqual(store.object(forKey: PreferenceKey.gridNullDisplayText.rawValue) as? String, "(null)")

        // 新建实例读到同样的值
        let reloaded = Preferences(store: store)
        XCTAssertEqual(reloaded.pageSize, 1000)
        XCTAssertEqual(reloaded.nullDisplayText, "(null)")
        XCTAssertEqual(reloaded.csvDelimiter, .tab)
        XCTAssertEqual(reloaded.defaultExecutionScope, .allStatements)
        XCTAssertFalse(reloaded.lazyLargeColumns)
    }

    func testClamping() {
        let preferences = Preferences(store: InMemoryKeyValueStore())

        preferences.pageSize = 999_999
        XCTAssertEqual(preferences.pageSize, PageSize.maximum)
        preferences.pageSize = 0
        XCTAssertEqual(preferences.pageSize, 1)

        preferences.inspectorWidth = 10
        XCTAssertEqual(preferences.inspectorWidth, 260)
        preferences.inspectorWidth = 5000
        XCTAssertEqual(preferences.inspectorWidth, 560)

        preferences.gridFontSize = 1
        XCTAssertEqual(preferences.gridFontSize, 8)
        preferences.indentWidth = 100
        XCTAssertEqual(preferences.indentWidth, 16)

        preferences.consoleLogCapacity = 0
        XCTAssertEqual(preferences.consoleLogCapacity, 100)
    }

    func testClampedValueIsPersisted() {
        let store = InMemoryKeyValueStore()
        let preferences = Preferences(store: store)
        preferences.inspectorWidth = 5
        XCTAssertEqual(store.object(forKey: PreferenceKey.gridInspectorWidth.rawValue) as? Double, 260)
    }

    func testResetToDefaults() {
        let store = InMemoryKeyValueStore()
        let preferences = Preferences(store: store)
        preferences.pageSize = 1000
        preferences.nullDisplayText = "(null)"
        preferences.consoleLogWriteToFile = true

        preferences.resetToDefaults()

        XCTAssertEqual(preferences.pageSize, 300)
        XCTAssertEqual(preferences.nullDisplayText, "NULL")
        XCTAssertFalse(preferences.consoleLogWriteToFile)
        XCTAssertEqual(Preferences(store: store).pageSize, 300)
    }

    func testEveryKeyHasDefaultValue() {
        for key in PreferenceKey.allCases {
            XCTAssertNotNil(key.defaultValue, "\(key.rawValue) 缺少默认值")
        }
    }

    func testUnknownStoredValueFallsBackToDefault() {
        let store = InMemoryKeyValueStore(storage: [
            PreferenceKey.csvDelimiter.rawValue: "not-a-delimiter",
            PreferenceKey.gridPageSize.rawValue: "不是数字",
        ])
        let preferences = Preferences(store: store)
        XCTAssertEqual(preferences.csvDelimiter, .comma)
        XCTAssertEqual(preferences.pageSize, 300)
    }
}
