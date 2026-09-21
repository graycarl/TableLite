import Combine
import Foundation

// MARK: - 偏好设置
//
// 所有键在这里集中声明并给出默认值，视图禁止直接读写 UserDefaults。
// 见 docs/tech-designs/02-persistence.md §6、specs/11-preferences.md。

enum CSVDelimiter: String, CaseIterable, Identifiable, Sendable {
    case comma
    case tab
    case semicolon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .comma: return "逗号"
        case .tab: return "制表符"
        case .semicolon: return "分号"
        }
    }

    var character: Character {
        switch self {
        case .comma: return ","
        case .tab: return "\t"
        case .semicolon: return ";"
        }
    }
}

enum CSVLineEnding: String, CaseIterable, Identifiable, Sendable {
    case lf
    case crlf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        }
    }

    var text: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        }
    }
}

enum CSVEncoding: String, CaseIterable, Identifiable, Sendable {
    case utf8
    case utf8BOM

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        }
    }
}

enum CSVNullStyle: String, CaseIterable, Identifiable, Sendable {
    case empty
    case literalNULL

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .empty: return "空字符串"
        case .literalNULL: return "NULL 字面量"
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {

    private enum Key {
        static let restoreSession = "general.restoreSession"
        static let restoreDrafts = "general.restoreDrafts"
        static let idleDisconnect = "general.idleDisconnect"

        static let defaultQueryTimeout = "connection.defaultQueryTimeout"
        static let defaultKeepAlive = "connection.defaultKeepAlive"
        static let keepAliveInterval = "connection.keepAliveInterval"
        static let maxConnections = "connection.maxConnections"

        static let pageSize = "grid.pageSize"
        static let gridFontSize = "grid.fontSize"
        static let gridAlternatingRows = "grid.alternatingRows"
        static let gridAutoHideScroller = "grid.autoHideScroller"
        static let largeValueThreshold = "grid.largeValueThreshold"
        static let nullDisplayText = "grid.nullDisplayText"
        static let tinyInt1AsBool = "grid.tinyInt1AsBool"
        static let showRowInspector = "grid.showRowInspector"
        static let rowInspectorWidth = "grid.rowInspectorWidth"
        static let rememberTableState = "grid.rememberTableState"
        static let rememberTableFilters = "grid.rememberTableFilters"
        static let lazyLargeColumns = "grid.lazyLargeColumns"

        static let editorFontName = "editor.fontName"
        static let editorFontSize = "editor.fontSize"
        static let editorIndentWidth = "editor.indentWidth"
        static let editorDefaultExecuteAll = "editor.defaultExecuteAll"
        static let editorStopOnError = "editor.stopOnError"
        static let editorHighlightCurrentStatement = "editor.highlightCurrentStatement"
        static let editorShowLineNumbers = "editor.showLineNumbers"
        static let editorAutoSaveDrafts = "editor.autoSaveDrafts"

        static let csvDelimiter = "csv.delimiter"
        static let csvLineEnding = "csv.lineEnding"
        static let csvIncludeHeader = "csv.includeHeader"
        static let csvEncoding = "csv.encoding"
        static let csvNullStyle = "csv.nullStyle"

        static let showSystemDatabases = "ui.showSystemDatabases"
        static let sidebarWidth = "ui.sidebarWidth"
        static let sidebarVisible = "ui.sidebarVisible"
        static let editorSplitRatio = "ui.editorSplitRatio"

        static let consoleLogCapacity = "console.capacity"
        static let consoleLogWriteToFile = "console.writeToFile"
        static let consoleLogAutoScroll = "console.autoScroll"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: 通用

    var restoreSession: Bool {
        get { read(Key.restoreSession, true) }
        set { write(Key.restoreSession, newValue) }
    }

    var restoreDrafts: Bool {
        get { read(Key.restoreDrafts, true) }
        set { write(Key.restoreDrafts, newValue) }
    }

    var idleDisconnect: Bool {
        get { read(Key.idleDisconnect, true) }
        set { write(Key.idleDisconnect, newValue) }
    }

    // MARK: 连接

    var defaultQueryTimeout: Int {
        get { read(Key.defaultQueryTimeout, 300) }
        set { write(Key.defaultQueryTimeout, newValue) }
    }

    var defaultKeepAlive: Bool {
        get { read(Key.defaultKeepAlive, true) }
        set { write(Key.defaultKeepAlive, newValue) }
    }

    var keepAliveInterval: Int {
        get { read(Key.keepAliveInterval, 30) }
        set { write(Key.keepAliveInterval, newValue) }
    }

    var maxConnections: Int {
        get { read(Key.maxConnections, 8) }
        set { write(Key.maxConnections, newValue) }
    }

    // MARK: 表数据

    var pageSize: Int {
        get { read(Key.pageSize, 300) }
        set { write(Key.pageSize, newValue) }
    }

    var gridFontSize: Double {
        get { read(Key.gridFontSize, 13) }
        set { write(Key.gridFontSize, newValue) }
    }

    var gridAlternatingRows: Bool {
        get { read(Key.gridAlternatingRows, true) }
        set { write(Key.gridAlternatingRows, newValue) }
    }

    var gridAutoHideScroller: Bool {
        get { read(Key.gridAutoHideScroller, true) }
        set { write(Key.gridAutoHideScroller, newValue) }
    }

    var largeValueThreshold: Int {
        get { read(Key.largeValueThreshold, 4096) }
        set { write(Key.largeValueThreshold, newValue) }
    }

    var nullDisplayText: String {
        get { read(Key.nullDisplayText, "NULL") }
        set { write(Key.nullDisplayText, newValue) }
    }

    var tinyInt1AsBool: Bool {
        get { read(Key.tinyInt1AsBool, false) }
        set { write(Key.tinyInt1AsBool, newValue) }
    }

    var showRowInspector: Bool {
        get { read(Key.showRowInspector, true) }
        set { write(Key.showRowInspector, newValue) }
    }

    var rowInspectorWidth: Double {
        get { read(Key.rowInspectorWidth, 320) }
        set { write(Key.rowInspectorWidth, newValue) }
    }

    var rememberTableState: Bool {
        get { read(Key.rememberTableState, true) }
        set { write(Key.rememberTableState, newValue) }
    }

    var rememberTableFilters: Bool {
        get { read(Key.rememberTableFilters, true) }
        set { write(Key.rememberTableFilters, newValue) }
    }

    var lazyLargeColumns: Bool {
        get { read(Key.lazyLargeColumns, true) }
        set { write(Key.lazyLargeColumns, newValue) }
    }

    // MARK: SQL 编辑器

    /// 空字符串表示系统等宽字体
    var editorFontName: String {
        get { read(Key.editorFontName, "") }
        set { write(Key.editorFontName, newValue) }
    }

    var editorFontSize: Double {
        get { read(Key.editorFontSize, 13) }
        set { write(Key.editorFontSize, newValue) }
    }

    var editorIndentWidth: Int {
        get { read(Key.editorIndentWidth, 4) }
        set { write(Key.editorIndentWidth, newValue) }
    }

    var editorDefaultExecuteAll: Bool {
        get { read(Key.editorDefaultExecuteAll, false) }
        set { write(Key.editorDefaultExecuteAll, newValue) }
    }

    var editorStopOnError: Bool {
        get { read(Key.editorStopOnError, true) }
        set { write(Key.editorStopOnError, newValue) }
    }

    var editorHighlightCurrentStatement: Bool {
        get { read(Key.editorHighlightCurrentStatement, true) }
        set { write(Key.editorHighlightCurrentStatement, newValue) }
    }

    var editorShowLineNumbers: Bool {
        get { read(Key.editorShowLineNumbers, true) }
        set { write(Key.editorShowLineNumbers, newValue) }
    }

    var editorAutoSaveDrafts: Bool {
        get { read(Key.editorAutoSaveDrafts, true) }
        set { write(Key.editorAutoSaveDrafts, newValue) }
    }

    // MARK: CSV 与导出

    var csvDelimiter: CSVDelimiter {
        get { readEnum(Key.csvDelimiter, .comma) }
        set { write(Key.csvDelimiter, newValue.rawValue) }
    }

    var csvLineEnding: CSVLineEnding {
        get { readEnum(Key.csvLineEnding, .lf) }
        set { write(Key.csvLineEnding, newValue.rawValue) }
    }

    var csvIncludeHeader: Bool {
        get { read(Key.csvIncludeHeader, true) }
        set { write(Key.csvIncludeHeader, newValue) }
    }

    var csvEncoding: CSVEncoding {
        get { readEnum(Key.csvEncoding, .utf8) }
        set { write(Key.csvEncoding, newValue.rawValue) }
    }

    var csvNullStyle: CSVNullStyle {
        get { readEnum(Key.csvNullStyle, .empty) }
        set { write(Key.csvNullStyle, newValue.rawValue) }
    }

    // MARK: 界面

    var showSystemDatabases: Bool {
        get { read(Key.showSystemDatabases, false) }
        set { write(Key.showSystemDatabases, newValue) }
    }

    var sidebarWidth: Double {
        get { read(Key.sidebarWidth, 240) }
        set { write(Key.sidebarWidth, newValue) }
    }

    var sidebarVisible: Bool {
        get { read(Key.sidebarVisible, true) }
        set { write(Key.sidebarVisible, newValue) }
    }

    var editorSplitRatio: Double {
        get { read(Key.editorSplitRatio, 0.4) }
        set { write(Key.editorSplitRatio, newValue) }
    }

    // MARK: Console Log

    var consoleLogCapacity: Int {
        get { read(Key.consoleLogCapacity, 5000) }
        set { write(Key.consoleLogCapacity, newValue) }
    }

    var consoleLogWriteToFile: Bool {
        get { read(Key.consoleLogWriteToFile, false) }
        set { write(Key.consoleLogWriteToFile, newValue) }
    }

    var consoleLogAutoScroll: Bool {
        get { read(Key.consoleLogAutoScroll, true) }
        set { write(Key.consoleLogAutoScroll, newValue) }
    }

    // MARK: 读写

    private func read<T>(_ key: String, _ fallback: T) -> T {
        (defaults.object(forKey: key) as? T) ?? fallback
    }

    private func write<T>(_ key: String, _ value: T) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }

    private func readEnum<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }
}

// MARK: - 按表记忆的展示状态（列宽 / 列显隐 / 过滤 / 排序）
//
// 键：`connectionID/schema.table`。见 docs/tech-designs/07-data-grid.md §2。

@MainActor
final class TableStateStore {
    private let defaults: UserDefaults
    private let keyPrefix = "tableState."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(connectionID: UUID, table: TableRef) -> TablePresentationState {
        let key = keyPrefix + "\(connectionID.uuidString)/\(table.displayName)"
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(TablePresentationState.self, from: data) else {
            return TablePresentationState()
        }
        return state
    }

    func save(_ state: TablePresentationState, connectionID: UUID, table: TableRef) {
        let key = keyPrefix + "\(connectionID.uuidString)/\(table.displayName)"
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func removeState(connectionID: UUID, table: TableRef) {
        defaults.removeObject(forKey: keyPrefix + "\(connectionID.uuidString)/\(table.displayName)")
    }

    func removeAll(connectionID: UUID) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(keyPrefix + connectionID.uuidString + "/") {
            defaults.removeObject(forKey: key)
        }
    }
}
