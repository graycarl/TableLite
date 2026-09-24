import Foundation

// MARK: - 选项枚举

/// CSV 默认分隔符（`specs/11-preferences.md` §5）。
///
/// 换行符 / 编码 / `NULL` 表示复用 `Core/SQL/CSVCodec.swift` 里的
/// `CSVLineEnding` / `CSVTextEncoding` / `CSVNullRepresentation`，不重复定义。
public enum CSVExportDelimiter: String, Codable, Sendable, CaseIterable {
    case comma
    case tab
    case semicolon

    public var displayName: String {
        switch self {
        case .comma: return "逗号"
        case .tab: return "制表符"
        case .semicolon: return "分号"
        }
    }

    /// `CSVWriteOptions.delimiter` 用的字节。
    public var byte: UInt8 {
        switch self {
        case .comma: return 0x2C
        case .tab: return 0x09
        case .semicolon: return 0x3B
        }
    }

    public init?(byte: UInt8) {
        switch byte {
        case 0x2C: self = .comma
        case 0x09: self = .tab
        case 0x3B: self = .semicolon
        default: return nil
        }
    }
}

/// 默认执行行为（`specs/11-preferences.md` §4、`specs/06-query-editor.md` §3）。
public enum SQLExecutionScope: String, Codable, Sendable, CaseIterable {
    case currentStatement
    case allStatements

    public var displayName: String {
        switch self {
        case .currentStatement: return "执行当前语句"
        case .allStatements: return "执行全部"
        }
    }
}

/// 界面语言（`specs/11-preferences.md` §6、`06-ui-layer.md` §8：当前只有中文）。
public enum InterfaceLanguage: String, Codable, Sendable, CaseIterable {
    case chinese

    public var displayName: String {
        switch self {
        case .chinese: return "中文"
        }
    }
}

/// 外观（`specs/11-preferences.md` §6、`06-ui-layer.md` §9）。
///
/// 到 `ColorScheme` 的映射在 UI 层（`AppearanceMode+UI.swift`），Core 层不依赖 SwiftUI。
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case light
    case dark
    case system

    public var displayName: String {
        switch self {
        case .light: return "亮色"
        case .dark: return "暗色"
        case .system: return "跟随系统"
        }
    }
}

// MARK: - 键与默认值

/// 全部偏好键。
///
/// `02-persistence.md` §6：键名格式 `<域>.<项>`；**所有键在这里集中声明并给出默认值**，
/// 禁止在视图里直接读写 `UserDefaults`。默认值取自 `specs/11-preferences.md`。
public enum PreferenceKey: String, CaseIterable, Sendable {

    // 通用（specs/11 §1）
    case restoreLastScript = "general.restoreLastScript"
    case idleDisconnect = "general.idleDisconnect"
    case reportCrashes = "general.reportCrashes"

    // 连接（specs/11 §2）
    case defaultQueryTimeout = "connection.defaultQueryTimeout"
    case defaultKeepAlive = "connection.defaultKeepAlive"
    case keepAliveInterval = "connection.keepAliveInterval"
    case maxSessions = "connection.maxSessions"

    // 表数据（specs/11 §3）
    case gridRowLimit = "grid.pageSize"
    case gridFontSize = "grid.fontSize"
    case gridAlternateRowColors = "grid.alternateRowColors"
    case gridAutoHideScrollers = "grid.autoHideScrollers"
    case gridLazyLargeColumns = "grid.lazyLargeColumns"
    case gridLazyLargeThreshold = "grid.lazyLargeColumnThreshold"
    case gridNullDisplayText = "grid.nullDisplayText"
    case gridTinyintAsCheckbox = "grid.tinyintAsCheckbox"
    case gridShowInspector = "grid.showInspector"
    case gridInspectorWidth = "grid.inspectorWidth"
    case gridRememberColumnLayout = "grid.rememberColumnLayout"
    case gridRememberFilters = "grid.rememberFilters"

    // SQL 编辑器（specs/11 §4）
    case editorFontName = "editor.fontName"
    case editorFontSize = "editor.fontSize"
    case editorIndentWidth = "editor.indentWidth"
    case editorExecutionScope = "editor.defaultExecutionScope"
    case editorStopOnError = "editor.stopOnError"
    case editorHighlightCurrentStatement = "editor.highlightCurrentStatement"
    case editorShowLineNumbers = "editor.showLineNumbers"
    case editorAutoSaveDraft = "editor.autoSaveDraft"

    // CSV 与导出（specs/11 §5）
    case csvDelimiter = "csv.delimiter"
    case csvLineEnding = "csv.lineEnding"
    case csvIncludeHeader = "csv.includeHeader"
    case csvEncoding = "csv.encoding"
    case csvNullRepresentation = "csv.nullRepresentation"

    // 界面（specs/11 §6）
    case uiAppearance = "ui.appearance"
    case uiShowSystemDatabases = "ui.showSystemDatabases"
    case uiSidebarWidth = "ui.sidebarWidth"
    case uiEditorResultSplitRatio = "ui.editorResultSplitRatio"
    case uiLanguage = "ui.language"

    // Console Log（specs/11 §7）
    case consoleLogCapacity = "consoleLog.capacity"
    case consoleLogWriteToFile = "consoleLog.writeToFile"
    case consoleLogScrollToBottom = "consoleLog.scrollToBottom"

    /// 默认值。类型由具体项决定（Bool / Int / Double / String / 枚举 rawValue）。
    public var defaultValue: Any? {
        switch self {
        case .restoreLastScript: return true
        case .idleDisconnect: return true
        case .reportCrashes: return false

        case .defaultQueryTimeout: return 300
        case .defaultKeepAlive: return true
        case .keepAliveInterval: return 30
        case .maxSessions: return 8

        case .gridRowLimit: return 300
        case .gridFontSize: return 13
        case .gridAlternateRowColors: return true
        case .gridAutoHideScrollers: return true
        case .gridLazyLargeColumns: return true
        case .gridLazyLargeThreshold: return 4096
        case .gridNullDisplayText: return "NULL"
        case .gridTinyintAsCheckbox: return false
        case .gridShowInspector: return true
        case .gridInspectorWidth: return 320.0
        case .gridRememberColumnLayout: return true
        case .gridRememberFilters: return true

        case .editorFontName: return ""
        case .editorFontSize: return 13
        case .editorIndentWidth: return 4
        case .editorExecutionScope: return SQLExecutionScope.currentStatement.rawValue
        case .editorStopOnError: return true
        case .editorHighlightCurrentStatement: return true
        case .editorShowLineNumbers: return true
        case .editorAutoSaveDraft: return true

        case .csvDelimiter: return CSVExportDelimiter.comma.rawValue
        case .csvLineEnding: return CSVLineEnding.lf.rawValue
        case .csvIncludeHeader: return true
        case .csvEncoding: return CSVTextEncoding.utf8.rawValue
        case .csvNullRepresentation: return CSVNullRepresentation.emptyString.rawValue

        case .uiAppearance: return AppearanceMode.system.rawValue
        case .uiShowSystemDatabases: return false
        case .uiSidebarWidth: return 220.0
        case .uiEditorResultSplitRatio: return 0.5
        case .uiLanguage: return InterfaceLanguage.chinese.rawValue

        case .consoleLogCapacity: return 5000
        case .consoleLogWriteToFile: return false
        case .consoleLogScrollToBottom: return true
        }
    }
}
