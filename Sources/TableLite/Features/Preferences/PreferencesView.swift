import SwiftUI
import AppKit

/// 偏好设置窗口（`specs/11-preferences.md`、manual/11-preferences.html）。
///
/// 四个分类：通用 / SQL 编辑器 / 表数据 / 高级。全部选项直接绑定 `Preferences`（@Observable），
/// 改动即时持久化、即时生效。CSV 默认值已移到导出面板，Console Log 选项在日志标签菜单里。
struct PreferencesView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var selection = Category.general

    /// 左侧分类（顺序即说明书顺序）。
    enum Category: String, CaseIterable, Identifiable {
        case general
        case editor
        case grid
        case advanced

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "通用"
            case .editor: "SQL 编辑器"
            case .grid: "表数据"
            case .advanced: "高级"
            }
        }
    }

    var body: some View {
        @Bindable var preferences = environment.preferences

        NavigationSplitView {
            List(Category.allCases, selection: $selection) { category in
                Text(category.title)
                    .tag(category)
                    .accessibilityIdentifier("preferences.category.\(category.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.title)
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                Form {
                    switch selection {
                    case .general: generalRows(preferences)
                    case .editor: editorRows(preferences)
                    case .grid: gridRows(preferences)
                    case .advanced: advancedRows(preferences)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("偏好设置")
        .frame(width: 700, height: 540)
        // 偏好设置是独立 Scene，必须单独挂一次（`06-ui-layer.md` §9）。
        .preferredColorScheme(environment.preferences.appearance.preferredColorScheme)
    }

    // MARK: 通用

    @ViewBuilder
    private func generalRows(_ preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        LabeledContent("外观") {
            Picker("外观", selection: $preferences.appearance) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
        Text("亮色 / 暗色 / 跟随系统，改完立刻生效。")
            .preferenceCaption()

        Toggle("恢复上次的脚本内容", isOn: $preferences.restoreLastScript)
        Text("查询标签重新打开时恢复上次的编辑内容。")
            .preferenceCaption()

        Toggle("空闲自动断开连接", isOn: $preferences.idleDisconnect)
        Text("空闲 5 分钟且没有标签引用时自动断开。")
            .preferenceCaption()

        Toggle("显示系统数据库", isOn: $preferences.showSystemDatabases)
        Text("对象树里显示 information_schema 等系统库。")
            .preferenceCaption()
    }

    // MARK: SQL 编辑器

    @ViewBuilder
    private func editorRows(_ preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        Picker("字体", selection: $preferences.editorFontName) {
            Text("系统等宽字体").tag("")
            ForEach(Self.availableMonospaceFonts, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        LabeledContent("字号") {
            Stepper(value: $preferences.editorFontSize, in: Preferences.fontSizeRange) {
                Text("\(preferences.editorFontSize)")
                    .monospacedDigit()
            }
        }
        LabeledContent("缩进宽度（空格）") {
            Stepper(value: $preferences.indentWidth, in: Preferences.indentWidthRange) {
                Text("\(preferences.indentWidth)")
                    .monospacedDigit()
            }
        }
        Picker("默认执行行为", selection: $preferences.defaultExecutionScope) {
            ForEach(SQLExecutionScope.allCases, id: \.self) { scope in
                Text(scope.displayName).tag(scope)
            }
        }
        Toggle("遇到错误时停止", isOn: $preferences.stopOnError)
        Text("关闭后会继续执行后续语句，一次看到所有错误。")
            .preferenceCaption()
        Toggle("高亮当前语句", isOn: $preferences.highlightCurrentStatement)
        Toggle("显示行号", isOn: $preferences.showLineNumbers)
        Toggle("自动保存脚本草稿", isOn: $preferences.autoSaveDraft)
    }

    /// 系统里可用的常见等宽字体（候选清单过滤，避免枚举全部字体）。
    static let availableMonospaceFonts: [String] = {
        let candidates = [
            "Menlo", "Monaco", "Courier", "Courier New", "Andale Mono",
            "PT Mono", "JetBrains Mono", "Fira Code", "Source Code Pro",
            "Hack", "IBM Plex Mono", "SF Mono",
        ]
        return candidates.filter { NSFont(name: $0, size: 13) != nil }
    }()

    // MARK: 表数据

    @ViewBuilder
    private func gridRows(_ preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        Picker("默认显示行数", selection: $preferences.rowLimit) {
            ForEach([100, 300, 1000, 5000], id: \.self) { size in
                Text("\(size)").tag(size)
            }
        }
        LabeledContent("字号") {
            Stepper(value: $preferences.gridFontSize, in: Preferences.fontSizeRange) {
                Text("\(preferences.gridFontSize)")
                    .monospacedDigit()
            }
        }
        Toggle("交替行底色", isOn: $preferences.alternateRowColors)
        Text("只作用于有数据的行；空白区域不画斑马纹。")
            .preferenceCaption()
        Toggle("自动隐藏滚动条", isOn: $preferences.autoHideScrollers)
        Toggle("超长内容延迟加载", isOn: $preferences.lazyLargeColumns)
        LabeledContent("NULL 的显示文本") {
            TextField("NULL", text: $preferences.nullDisplayText)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
        Toggle("把 tinyint(1) 显示为复选框", isOn: $preferences.tinyintAsCheckbox)
        Toggle("显示右侧字段栏", isOn: $preferences.showInspector)
        Text("关闭后选中行也不显示字段栏，可用工具栏按钮再打开。")
            .preferenceCaption()
        LabeledContent("右侧字段栏宽度") {
            Slider(value: $preferences.inspectorWidth,
                   in: Preferences.inspectorWidthRange) {
                Text("\(Int(preferences.inspectorWidth))")
            }
            .frame(width: 160)
        }
        Toggle("记住每张表的列宽与列显隐", isOn: $preferences.rememberColumnLayout)
        Toggle("记住每张表的过滤条件", isOn: $preferences.rememberFilters)
    }

    // MARK: 高级

    @ViewBuilder
    private func advancedRows(_ preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        LabeledContent("默认查询超时（秒）") {
            Stepper(value: $preferences.defaultQueryTimeout, in: 5...86_400, step: 5) {
                Text("\(preferences.defaultQueryTimeout)")
                    .monospacedDigit()
            }
        }
        Toggle("默认保持连接活跃", isOn: $preferences.defaultKeepAlive)
        LabeledContent("心跳间隔（秒）") {
            Stepper(value: $preferences.keepAliveInterval, in: 5...600, step: 5) {
                Text("\(preferences.keepAliveInterval)")
                    .monospacedDigit()
            }
        }
        LabeledContent("同时保持的连接数上限") {
            Stepper(value: $preferences.maxSessions, in: 1...32) {
                Text("\(preferences.maxSessions)")
                    .monospacedDigit()
            }
        }
        LabeledContent("超长内容截断阈值（字节）") {
            TextField("", value: $preferences.lazyLargeColumnThreshold, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
        Text("超过该长度的文本 / 二进制列会延迟加载。")
            .preferenceCaption()
        LabeledContent("编辑器 / 结果区分割比例") {
            Slider(value: $preferences.editorResultSplitRatio, in: 0.15...0.85)
                .frame(width: 160)
        }
        LabeledContent("Console Log 保留条数") {
            Stepper(value: $preferences.consoleLogCapacity, in: Preferences.consoleLogCapacityRange, step: 500) {
                Text("\(preferences.consoleLogCapacity)")
                    .monospacedDigit()
            }
        }
        Toggle("Console Log 写入日志文件", isOn: $preferences.consoleLogWriteToFile)
        Text("打开后写入本地日志，按天轮转保留 7 天。")
            .preferenceCaption()
        Toggle("打开 Console Log 时自动滚到底部", isOn: $preferences.consoleLogScrollToBottom)
    }
}

private extension View {
    /// 偏好说明文字（13pt 灰字）。
    func preferenceCaption() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
    }
}
