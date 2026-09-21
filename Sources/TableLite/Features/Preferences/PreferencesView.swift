import AppKit
import SwiftUI

// MARK: - PreferencesView

/// 偏好设置。七个分组：通用 / 连接 / 表数据 / SQL 编辑器 / CSV 与导出 / 界面 / Console Log。
/// 全部即时生效，没有「应用」按钮。见 `specs/11-preferences.md`。
struct PreferencesView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        PreferencesTabs(preferences: env.preferences)
    }
}

private struct PreferencesTabs: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        TabView {
            general.formStyle(.grouped).tabItem { Text("通用") }
            connection.formStyle(.grouped).tabItem { Text("连接") }
            tableData.formStyle(.grouped).tabItem { Text("表数据") }
            editor.formStyle(.grouped).tabItem { Text("SQL 编辑器") }
            csv.formStyle(.grouped).tabItem { Text("CSV 与导出") }
            interface.formStyle(.grouped).tabItem { Text("界面") }
            consoleLog.formStyle(.grouped).tabItem { Text("Console Log") }
        }
        .frame(width: 720, height: 560)
        .padding(16)
    }

    // MARK: 通用

    private var general: some View {
        Form {
            Section("通用") {
                PrefToggle(title: "恢复上次打开的标签",
                           help: "重启 App 后恢复上次的连接与标签；只恢复骨架，不自动重连",
                           isOn: binding(\.restoreSession))
                PrefToggle(title: "恢复上次的脚本内容",
                           help: "查询标签重新打开时恢复上次的编辑内容",
                           isOn: binding(\.restoreDrafts))
                PrefToggle(title: "空闲自动断开连接",
                           help: "空闲 5 分钟且没有标签引用时自动断开",
                           isOn: binding(\.idleDisconnect))
            }
        }
    }

    // MARK: 连接

    private var connection: some View {
        Form {
            Section("连接") {
                PrefNumberField(title: "默认查询超时", unit: "秒",
                                help: "新建连接时的默认值",
                                value: binding(\.defaultQueryTimeout))
                PrefToggle(title: "默认保持连接活跃",
                           help: "新建连接时的默认值",
                           isOn: binding(\.defaultKeepAlive))
                PrefNumberField(title: "心跳间隔", unit: "秒",
                                help: nil,
                                value: binding(\.keepAliveInterval))
                PrefNumberField(title: "同时保持的连接数上限", unit: nil,
                                help: "超过后会提示先断开一个",
                                value: binding(\.maxConnections))
            }
        }
    }

    // MARK: 表数据

    private var tableData: some View {
        Form {
            Section("表数据") {
                HStack(spacing: 8) {
                    PrefLabel("每页行数")
                    Picker("", selection: binding(\.pageSize)) {
                        Text("100").tag(100)
                        Text("300").tag(300)
                        Text("1000").tag(1000)
                        Text("5000").tag(5000)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    PrefHelp("可选 100 / 300 / 1000 / 5000")
                }

                PrefDoubleField(title: "字号", unit: nil, help: nil, value: binding(\.gridFontSize))
                PrefToggle(title: "交替行底色", help: "关闭后所有行同色",
                           isOn: binding(\.gridAlternatingRows))
                PrefToggle(title: "自动隐藏滚动条", help: nil,
                           isOn: binding(\.gridAutoHideScroller))
                PrefNumberField(title: "超长内容截断阈值", unit: "字节",
                                help: "超过该长度的文本 / 二进制列会延迟加载",
                                value: binding(\.largeValueThreshold))

                HStack(spacing: 8) {
                    PrefLabel("NULL 的显示文本")
                    TextField("", text: binding(\.nullDisplayText))
                        .frame(width: 140)
                    PrefHelp("可改为 (null)、<空> 等")
                }

                PrefToggle(title: "把 tinyint(1) 显示为复选框",
                           help: "打开后该类型以三态复选框呈现",
                           isOn: binding(\.tinyInt1AsBool))
                PrefToggle(title: "显示右侧字段栏",
                           help: "关闭后打开表时不显示字段栏，可用工具栏按钮再打开",
                           isOn: binding(\.showRowInspector))
                PrefDoubleField(title: "右侧字段栏宽度", unit: "pt",
                                help: "可拖拽，260–560pt，全局记住",
                                value: rowInspectorWidth)
                PrefToggle(title: "记住每张表的列宽与列显隐", help: nil,
                           isOn: binding(\.rememberTableState))
                PrefToggle(title: "记住每张表的过滤条件",
                           help: "下次打开这张表时恢复上次的过滤条件",
                           isOn: binding(\.rememberTableFilters))
            }
        }
    }

    // MARK: SQL 编辑器

    private var editor: some View {
        Form {
            Section("SQL 编辑器") {
                HStack(spacing: 8) {
                    PrefLabel("字体")
                    Picker("", selection: binding(\.editorFontName)) {
                        Text("系统等宽字体").tag("")
                        ForEach(monospacedFonts, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    PrefHelp("只能选系统里已安装的等宽字体")
                }

                PrefDoubleField(title: "字号", unit: nil, help: "改完立刻生效",
                                value: binding(\.editorFontSize))
                PrefNumberField(title: "缩进宽度", unit: "空格", help: nil,
                                value: binding(\.editorIndentWidth))

                HStack(spacing: 8) {
                    PrefLabel("默认执行行为")
                    Picker("", selection: binding(\.editorDefaultExecuteAll)) {
                        Text("执行当前语句").tag(false)
                        Text("执行全部").tag(true)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    PrefHelp("可改为「执行全部」")
                }

                PrefToggle(title: "遇到错误时停止",
                           help: "关闭后会继续执行后续语句，一次看到所有错误",
                           isOn: binding(\.editorStopOnError))
                PrefToggle(title: "高亮当前语句", help: nil,
                           isOn: binding(\.editorHighlightCurrentStatement))
                PrefToggle(title: "显示行号", help: nil,
                           isOn: binding(\.editorShowLineNumbers))
                PrefToggle(title: "自动保存脚本草稿", help: nil,
                           isOn: binding(\.editorAutoSaveDrafts))
            }
        }
    }

    // MARK: CSV 与导出

    private var csv: some View {
        Form {
            Section("CSV 与导出") {
                EnumRow(title: "默认分隔符", selection: binding(\.csvDelimiter),
                        cases: CSVDelimiter.allCases, label: { $0.displayName })
                EnumRow(title: "默认换行符", selection: binding(\.csvLineEnding),
                        cases: CSVLineEnding.allCases, label: { $0.displayName })
                PrefToggle(title: "导出时包含表头", help: nil,
                           isOn: binding(\.csvIncludeHeader))
                EnumRow(title: "导出文本编码", selection: binding(\.csvEncoding),
                        cases: CSVEncoding.allCases, label: { $0.displayName })
                EnumRow(title: "NULL 的导出形式", selection: binding(\.csvNullStyle),
                        cases: CSVNullStyle.allCases, label: { $0.displayName })
            }
        }
    }

    // MARK: 界面

    private var interface: some View {
        Form {
            Section("界面") {
                PrefToggle(title: "显示系统数据库",
                           help: "打开后对象树里显示 information_schema、performance_schema、mysql、sys",
                           isOn: binding(\.showSystemDatabases))
                HStack(spacing: 8) {
                    PrefLabel("左侧栏宽度")
                    Text("自动记忆（当前 \(Int(preferences.sidebarWidth)) pt）")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 8) {
                    PrefLabel("编辑器 / 结果区分割比例")
                    Text("自动记忆（当前 \(String(format: "%.2f", preferences.editorSplitRatio))）")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: Console Log

    private var consoleLog: some View {
        Form {
            Section("Console Log") {
                PrefNumberField(title: "保留条数", unit: nil,
                                help: "内存中保留的最近条数",
                                value: binding(\.consoleLogCapacity))
                PrefToggle(title: "写入日志文件",
                           help: "打开后写入本地日志，按天轮转保留 7 天",
                           isOn: binding(\.consoleLogWriteToFile))
                PrefToggle(title: "打开时自动滚到底部", help: nil,
                           isOn: binding(\.consoleLogAutoScroll))
            }
        }
    }

    // MARK: 工具

    private var monospacedFonts: [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { NSFont(name: $0, size: 13)?.isFixedPitch == true }
            .sorted()
    }

    private var rowInspectorWidth: Binding<Double> {
        Binding(
            get: { preferences.rowInspectorWidth },
            set: { preferences.rowInspectorWidth = min(560, max(260, $0)) }
        )
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<PreferencesStore, T>) -> Binding<T> {
        Binding(get: { preferences[keyPath: keyPath] },
                set: { preferences[keyPath: keyPath] = $0 })
    }
}

// MARK: - 行组件

private struct PrefLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .frame(width: 200, alignment: .trailing)
    }
}

private struct PrefHelp: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct PrefToggle: View {
    let title: String
    var help: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $isOn)
            if let help {
                PrefHelp(help)
            }
        }
    }
}

private struct PrefNumberField: View {
    let title: String
    var unit: String?
    var help: String?
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 8) {
            PrefLabel(title)
            TextField("", value: $value, format: .number)
                .frame(width: 80)
            if let unit {
                Text(unit).foregroundStyle(.secondary)
            }
            if let help {
                PrefHelp(help)
            }
            Spacer()
        }
    }
}

private struct PrefDoubleField: View {
    let title: String
    var unit: String?
    var help: String?
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            PrefLabel(title)
            TextField("", value: $value, format: .number)
                .frame(width: 80)
            if let unit {
                Text(unit).foregroundStyle(.secondary)
            }
            if let help {
                PrefHelp(help)
            }
            Spacer()
        }
    }
}

private struct EnumRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let cases: [Value]
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 8) {
            PrefLabel(title)
            Picker("", selection: $selection) {
                ForEach(cases, id: \.self) { item in
                    Text(label(item)).tag(item)
                }
            }
            .labelsHidden()
            .frame(width: 160)
            Spacer()
        }
    }
}
