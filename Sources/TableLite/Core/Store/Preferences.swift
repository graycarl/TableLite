import Foundation
import Observation

/// 偏好设置（面向 UI 的可观察对象）。
///
/// `02-persistence.md` §6：所有键在 `PreferenceKey` 集中声明并给出默认值，
/// 禁止在视图里直接读写 `UserDefaults`；敏感信息禁止进 `UserDefaults`。
///
/// 并发：`@MainActor` + `@Observable`，UI 直接绑定（`06-ui-layer.md` §2）。
/// 每个属性的 `didSet` 立刻通过 `PreferencesStore` 写回，做到「改了立刻生效」。
@MainActor
@Observable
public final class Preferences {

    // MARK: 取值范围

    public static let inspectorWidthRange: ClosedRange<Double> = 260...560
    public static let sidebarWidthRange: ClosedRange<Double> = 180...480
    public static let rowLimitRange: ClosedRange<Int> = 1...RowLimit.maximum
    public static let fontSizeRange: ClosedRange<Int> = 8...72
    public static let indentWidthRange: ClosedRange<Int> = 1...16
    public static let consoleLogCapacityRange: ClosedRange<Int> = 100...100_000
    public static let lazyLargeThresholdRange: ClosedRange<Int> = 256...10_485_760

    @ObservationIgnored private let storage: PreferencesStore

    // MARK: 通用（specs/11 §1）

    /// 恢复上次的脚本内容。
    public var restoreLastScript: Bool {
        didSet { persist(restoreLastScript, .restoreLastScript) }
    }
    /// 空闲 5 分钟且没有标签引用时自动断开。
    public var idleDisconnect: Bool {
        didSet { persist(idleDisconnect, .idleDisconnect) }
    }
    /// 报告崩溃（当前不出现，保留键）。
    public var reportCrashes: Bool {
        didSet { persist(reportCrashes, .reportCrashes) }
    }

    // MARK: 连接（specs/11 §2）

    /// 新建连接时的默认查询超时（秒）。
    public var defaultQueryTimeout: Int {
        didSet { persist(defaultQueryTimeout, .defaultQueryTimeout) }
    }
    /// 新建连接时的默认「保持连接活跃」。
    public var defaultKeepAlive: Bool {
        didSet { persist(defaultKeepAlive, .defaultKeepAlive) }
    }
    /// 心跳间隔（秒）。
    public var keepAliveInterval: Int {
        didSet { persist(keepAliveInterval, .keepAliveInterval) }
    }
    /// 同时保持的连接数上限。
    public var maxSessions: Int {
        didSet { persist(maxSessions, .maxSessions) }
    }

    // MARK: 表数据（specs/11 §3）

    /// 表数据默认显示行数（`specs/11-preferences.md` §3）。
    public var rowLimit: Int {
        didSet {
            let clamped = Self.clamp(rowLimit, to: Self.rowLimitRange)
            if clamped != rowLimit { rowLimit = clamped; return }
            persist(rowLimit, .gridRowLimit)
        }
    }
    /// 网格正文字号。
    public var gridFontSize: Int {
        didSet {
            let clamped = Self.clamp(gridFontSize, to: Self.fontSizeRange)
            if clamped != gridFontSize { gridFontSize = clamped; return }
            persist(gridFontSize, .gridFontSize)
        }
    }
    /// 交替行底色。
    public var alternateRowColors: Bool {
        didSet { persist(alternateRowColors, .gridAlternateRowColors) }
    }
    /// 自动隐藏滚动条。
    public var autoHideScrollers: Bool {
        didSet { persist(autoHideScrollers, .gridAutoHideScrollers) }
    }
    /// 大字段延迟加载（`07-data-grid.md` §3.1 引用的开关）。
    public var lazyLargeColumns: Bool {
        didSet { persist(lazyLargeColumns, .gridLazyLargeColumns) }
    }
    /// 超长内容截断阈值（字节）。
    public var lazyLargeColumnThreshold: Int {
        didSet {
            let clamped = Self.clamp(lazyLargeColumnThreshold, to: Self.lazyLargeThresholdRange)
            if clamped != lazyLargeColumnThreshold { lazyLargeColumnThreshold = clamped; return }
            persist(lazyLargeColumnThreshold, .gridLazyLargeThreshold)
        }
    }
    /// `NULL` 的显示文本。
    public var nullDisplayText: String {
        didSet { persist(nullDisplayText, .gridNullDisplayText) }
    }
    /// 把 `tinyint(1)` 显示为复选框。
    public var tinyintAsCheckbox: Bool {
        didSet { persist(tinyintAsCheckbox, .gridTinyintAsCheckbox) }
    }
    /// 显示右侧字段栏。
    public var showInspector: Bool {
        didSet { persist(showInspector, .gridShowInspector) }
    }
    /// 右侧字段栏宽度（全局共用，260–560pt）。
    public var inspectorWidth: Double {
        didSet {
            let clamped = Self.clamp(inspectorWidth, to: Self.inspectorWidthRange)
            if clamped != inspectorWidth { inspectorWidth = clamped; return }
            persist(inspectorWidth, .gridInspectorWidth)
        }
    }
    /// 记住每张表的列宽与列显隐。
    public var rememberColumnLayout: Bool {
        didSet { persist(rememberColumnLayout, .gridRememberColumnLayout) }
    }
    /// 记住每张表的过滤条件。
    public var rememberFilters: Bool {
        didSet { persist(rememberFilters, .gridRememberFilters) }
    }

    // MARK: SQL 编辑器（specs/11 §4）

    /// 编辑器字体名；空串表示系统等宽字体。
    public var editorFontName: String {
        didSet { persist(editorFontName, .editorFontName) }
    }
    /// 编辑器字号。
    public var editorFontSize: Int {
        didSet {
            let clamped = Self.clamp(editorFontSize, to: Self.fontSizeRange)
            if clamped != editorFontSize { editorFontSize = clamped; return }
            persist(editorFontSize, .editorFontSize)
        }
    }
    /// 缩进宽度（空格数）。
    public var indentWidth: Int {
        didSet {
            let clamped = Self.clamp(indentWidth, to: Self.indentWidthRange)
            if clamped != indentWidth { indentWidth = clamped; return }
            persist(indentWidth, .editorIndentWidth)
        }
    }
    /// 默认执行行为。
    public var defaultExecutionScope: SQLExecutionScope {
        didSet { persistChoice(defaultExecutionScope, .editorExecutionScope) }
    }
    /// 遇到错误时停止。
    public var stopOnError: Bool {
        didSet { persist(stopOnError, .editorStopOnError) }
    }
    /// 高亮当前语句。
    public var highlightCurrentStatement: Bool {
        didSet { persist(highlightCurrentStatement, .editorHighlightCurrentStatement) }
    }
    /// 显示行号。
    public var showLineNumbers: Bool {
        didSet { persist(showLineNumbers, .editorShowLineNumbers) }
    }
    /// 自动保存脚本草稿。
    public var autoSaveDraft: Bool {
        didSet { persist(autoSaveDraft, .editorAutoSaveDraft) }
    }

    // MARK: CSV 与导出（specs/11 §5）

    public var csvDelimiter: CSVExportDelimiter {
        didSet { persistChoice(csvDelimiter, .csvDelimiter) }
    }
    public var csvLineEnding: CSVLineEnding {
        didSet { persistChoice(csvLineEnding, .csvLineEnding) }
    }
    public var csvIncludeHeader: Bool {
        didSet { persist(csvIncludeHeader, .csvIncludeHeader) }
    }
    public var csvEncoding: CSVTextEncoding {
        didSet { persistChoice(csvEncoding, .csvEncoding) }
    }
    public var csvNullRepresentation: CSVNullRepresentation {
        didSet { persistChoice(csvNullRepresentation, .csvNullRepresentation) }
    }

    // MARK: 界面（specs/11 §6）

    /// 对象树里显示系统数据库。
    public var showSystemDatabases: Bool {
        didSet { persist(showSystemDatabases, .uiShowSystemDatabases) }
    }
    /// 左侧栏宽度（记忆）。
    public var sidebarWidth: Double {
        didSet {
            let clamped = Self.clamp(sidebarWidth, to: Self.sidebarWidthRange)
            if clamped != sidebarWidth { sidebarWidth = clamped; return }
            persist(sidebarWidth, .uiSidebarWidth)
        }
    }
    /// 编辑器 / 结果区分割比例（记忆）。
    public var editorResultSplitRatio: Double {
        didSet {
            let clamped = Self.clamp(editorResultSplitRatio, to: 0.1...0.9)
            if clamped != editorResultSplitRatio { editorResultSplitRatio = clamped; return }
            persist(editorResultSplitRatio, .uiEditorResultSplitRatio)
        }
    }
    /// 界面语言。
    public var language: InterfaceLanguage {
        didSet { persistChoice(language, .uiLanguage) }
    }

    // MARK: Console Log（specs/11 §7）

    /// 内存中保留的最近条数。
    public var consoleLogCapacity: Int {
        didSet {
            let clamped = Self.clamp(consoleLogCapacity, to: Self.consoleLogCapacityRange)
            if clamped != consoleLogCapacity { consoleLogCapacity = clamped; return }
            persist(consoleLogCapacity, .consoleLogCapacity)
        }
    }
    /// 写入日志文件（按天轮转，保留 7 天）。
    public var consoleLogWriteToFile: Bool {
        didSet { persist(consoleLogWriteToFile, .consoleLogWriteToFile) }
    }
    /// 打开时自动滚到底部。
    public var consoleLogScrollToBottom: Bool {
        didSet { persist(consoleLogScrollToBottom, .consoleLogScrollToBottom) }
    }

    // MARK: - 初始化

    /// 用真实 `UserDefaults` 构造（应用默认入口）。
    public convenience init(store: KeyValueStore = UserDefaultsKeyValueStore()) {
        self.init(preferencesStore: PreferencesStore(store: store))
    }

    /// 用指定持久化层构造（`AppEnvironment` 注入）。
    public init(preferencesStore: PreferencesStore) {
        self.storage = preferencesStore

        restoreLastScript = preferencesStore.bool(.restoreLastScript)
        idleDisconnect = preferencesStore.bool(.idleDisconnect)
        reportCrashes = preferencesStore.bool(.reportCrashes)

        defaultQueryTimeout = preferencesStore.integer(.defaultQueryTimeout)
        defaultKeepAlive = preferencesStore.bool(.defaultKeepAlive)
        keepAliveInterval = preferencesStore.integer(.keepAliveInterval)
        maxSessions = preferencesStore.integer(.maxSessions)

        rowLimit = Self.clamp(preferencesStore.integer(.gridRowLimit), to: Self.rowLimitRange)
        gridFontSize = Self.clamp(preferencesStore.integer(.gridFontSize), to: Self.fontSizeRange)
        alternateRowColors = preferencesStore.bool(.gridAlternateRowColors)
        autoHideScrollers = preferencesStore.bool(.gridAutoHideScrollers)
        lazyLargeColumns = preferencesStore.bool(.gridLazyLargeColumns)
        lazyLargeColumnThreshold = Self.clamp(
            preferencesStore.integer(.gridLazyLargeThreshold),
            to: Self.lazyLargeThresholdRange
        )
        nullDisplayText = preferencesStore.string(.gridNullDisplayText)
        tinyintAsCheckbox = preferencesStore.bool(.gridTinyintAsCheckbox)
        showInspector = preferencesStore.bool(.gridShowInspector)
        inspectorWidth = Self.clamp(preferencesStore.double(.gridInspectorWidth), to: Self.inspectorWidthRange)
        rememberColumnLayout = preferencesStore.bool(.gridRememberColumnLayout)
        rememberFilters = preferencesStore.bool(.gridRememberFilters)

        editorFontName = preferencesStore.string(.editorFontName)
        editorFontSize = Self.clamp(preferencesStore.integer(.editorFontSize), to: Self.fontSizeRange)
        indentWidth = Self.clamp(preferencesStore.integer(.editorIndentWidth), to: Self.indentWidthRange)
        defaultExecutionScope = preferencesStore.choice(
            .editorExecutionScope, SQLExecutionScope.self, fallback: .currentStatement
        )
        stopOnError = preferencesStore.bool(.editorStopOnError)
        highlightCurrentStatement = preferencesStore.bool(.editorHighlightCurrentStatement)
        showLineNumbers = preferencesStore.bool(.editorShowLineNumbers)
        autoSaveDraft = preferencesStore.bool(.editorAutoSaveDraft)

        csvDelimiter = preferencesStore.choice(.csvDelimiter, CSVExportDelimiter.self, fallback: .comma)
        csvLineEnding = preferencesStore.choice(.csvLineEnding, CSVLineEnding.self, fallback: .lf)
        csvIncludeHeader = preferencesStore.bool(.csvIncludeHeader)
        csvEncoding = preferencesStore.choice(.csvEncoding, CSVTextEncoding.self, fallback: .utf8)
        csvNullRepresentation = preferencesStore.choice(
            .csvNullRepresentation, CSVNullRepresentation.self, fallback: .emptyString
        )

        showSystemDatabases = preferencesStore.bool(.uiShowSystemDatabases)
        sidebarWidth = Self.clamp(preferencesStore.double(.uiSidebarWidth), to: Self.sidebarWidthRange)
        editorResultSplitRatio = Self.clamp(preferencesStore.double(.uiEditorResultSplitRatio), to: 0.1...0.9)
        language = preferencesStore.choice(.uiLanguage, InterfaceLanguage.self, fallback: .chinese)

        consoleLogCapacity = Self.clamp(
            preferencesStore.integer(.consoleLogCapacity),
            to: Self.consoleLogCapacityRange
        )
        consoleLogWriteToFile = preferencesStore.bool(.consoleLogWriteToFile)
        consoleLogScrollToBottom = preferencesStore.bool(.consoleLogScrollToBottom)
    }

    /// 恢复全部默认值（「恢复默认」用）。
    public func resetToDefaults() {
        storage.resetAll()
        let fresh = Preferences(preferencesStore: storage)
        restoreLastScript = fresh.restoreLastScript
        idleDisconnect = fresh.idleDisconnect
        reportCrashes = fresh.reportCrashes
        defaultQueryTimeout = fresh.defaultQueryTimeout
        defaultKeepAlive = fresh.defaultKeepAlive
        keepAliveInterval = fresh.keepAliveInterval
        maxSessions = fresh.maxSessions
        rowLimit = fresh.rowLimit
        gridFontSize = fresh.gridFontSize
        alternateRowColors = fresh.alternateRowColors
        autoHideScrollers = fresh.autoHideScrollers
        lazyLargeColumns = fresh.lazyLargeColumns
        lazyLargeColumnThreshold = fresh.lazyLargeColumnThreshold
        nullDisplayText = fresh.nullDisplayText
        tinyintAsCheckbox = fresh.tinyintAsCheckbox
        showInspector = fresh.showInspector
        inspectorWidth = fresh.inspectorWidth
        rememberColumnLayout = fresh.rememberColumnLayout
        rememberFilters = fresh.rememberFilters
        editorFontName = fresh.editorFontName
        editorFontSize = fresh.editorFontSize
        indentWidth = fresh.indentWidth
        defaultExecutionScope = fresh.defaultExecutionScope
        stopOnError = fresh.stopOnError
        highlightCurrentStatement = fresh.highlightCurrentStatement
        showLineNumbers = fresh.showLineNumbers
        autoSaveDraft = fresh.autoSaveDraft
        csvDelimiter = fresh.csvDelimiter
        csvLineEnding = fresh.csvLineEnding
        csvIncludeHeader = fresh.csvIncludeHeader
        csvEncoding = fresh.csvEncoding
        csvNullRepresentation = fresh.csvNullRepresentation
        showSystemDatabases = fresh.showSystemDatabases
        sidebarWidth = fresh.sidebarWidth
        editorResultSplitRatio = fresh.editorResultSplitRatio
        language = fresh.language
        consoleLogCapacity = fresh.consoleLogCapacity
        consoleLogWriteToFile = fresh.consoleLogWriteToFile
        consoleLogScrollToBottom = fresh.consoleLogScrollToBottom
    }

    // MARK: - 内部

    private func persist(_ value: Any?, _ key: PreferenceKey) {
        storage.set(value, for: key)
    }

    private func persistChoice<T: RawRepresentable>(_ value: T, _ key: PreferenceKey) where T.RawValue == String {
        storage.setChoice(value, for: key)
    }

    private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
