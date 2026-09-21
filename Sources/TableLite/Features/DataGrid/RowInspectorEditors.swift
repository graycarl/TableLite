import AppKit
import SwiftUI

// MARK: - 字段栏编辑器
//
// 编辑器映射见 docs/tech-designs/14-row-inspector.md §3、specs/04-data-editing.md §3。
// 校验是纯函数（`RowInspectorValidation`），控件只负责把值交给 ViewModel。

/// 字段值的校验（纯函数，可单测）。
enum RowInspectorValidation {
    enum Result: Equatable {
        case ok(CellValue)
        case invalid(String)
    }

    /// 校验并转换草稿文本。
    static func validate(_ draft: String, column: TableColumn) -> Result {
        switch column.kind {
        case .integer, .decimal, .floating:
            guard SQLValueLiteral.isStrictNumeric(draft) else {
                return .invalid("请输入合法数字（可含负号与小数点）")
            }
            return .ok(.text(draft))
        case .date:
            guard isDate(draft, format: "yyyy-MM-dd") else {
                return .invalid("日期格式应为 yyyy-MM-dd")
            }
            return .ok(.text(draft))
        case .dateTime, .timestamp:
            guard isDate(draft, format: "yyyy-MM-dd HH:mm:ss", allowFraction: true) else {
                return .invalid("日期时间格式应为 yyyy-MM-dd HH:mm:ss")
            }
            return .ok(.text(draft))
        case .time:
            guard isTime(draft) else {
                return .invalid("时间格式应为 HH:mm:ss")
            }
            return .ok(.text(draft))
        case .year:
            guard draft.count == 4, Int(draft) != nil else {
                return .invalid("年份应为 4 位数字")
            }
            return .ok(.text(draft))
        case .enumType:
            if let values = column.enumValues, !values.contains(draft) {
                return .invalid("请选择合法的枚举值")
            }
            return .ok(.text(draft))
        default:
            return .ok(.text(draft))
        }
    }

    static func isDate(_ text: String, format: String, allowFraction: Bool = false) -> Bool {
        if text.isEmpty { return true }
        let candidate = allowFraction ? String(text.prefix(19)) : text
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter.date(from: candidate) != nil
    }

    static func isTime(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let parts = text.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return false }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]) else { return false }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return false }
        if parts.count == 3 {
            // 秒可带小数
            let secondText = parts[2].split(separator: ".").first.map(String.init) ?? ""
            guard let second = Int(secondText), (0...59).contains(second) else { return false }
        }
        return true
    }
}

// MARK: - 单字段行

/// 字段栏里的一行：列名 + 类型 + 值编辑器 + `∅`。
struct RowInspectorFieldRow: View {
    @ObservedObject var model: TableDataViewModel
    @ObservedObject var preferences: PreferencesStore
    let row: TableDataRow
    let column: TableColumn
    let value: CellValue
    let isEditable: Bool
    let isDeleted: Bool

    /// 外部请求聚焦（网格双击）：等于本列名时抢焦点。
    @Binding var focusRequest: String?
    var onQuickLook: (RowIdentity, String) -> Void

    @State private var draft: String = ""
    @State private var lastNonNull: CellValue?
    @State private var error: String?
    @State private var shakeCount = 0
    @State private var isExpanded = false
    @FocusState private var isFocused: Bool

    private var isNull: Bool { value.isNull }

    private var isTruncated: Bool { model.isTruncated(row: row.identity, column: column.name) }

    private var isTruncatedNotLoaded: Bool {
        isTruncated && model.fullValue(row: row.identity, column: column.name) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                header
                Spacer(minLength: 4)
                valueEditor
                nullButton
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(rowBackground)
        .modifier(ShakeEffect(count: shakeCount))
        .onAppear {
            draft = EditorDraft.string(from: value, column: column)
            if focusRequest == column.name { isFocused = true; focusRequest = nil }
        }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            draft = EditorDraft.string(from: newValue, column: column)
        }
        .onChange(of: focusRequest) { _, newValue in
            guard newValue == column.name else { return }
            isFocused = true
            focusRequest = nil
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                beginEditing()
            } else {
                commit()
            }
        }
        .onDisappear {
            // 切换行 / 关闭字段栏时，把还在编辑的草稿提交到当前行（row.identity 已捕获）。
            commit()
        }
        .sheet(isPresented: $isExpanded) {
            ExpandedTextEditorSheet(title: column.name,
                                    text: draft,
                                    monospaced: column.kind == .json || column.kind == .text) { newText in
                draft = newText
                commit()
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 4) {
            if column.isPrimaryKey {
                Image(systemName: "key.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Text(column.name)
                .font(.system(size: 12, weight: column.isPrimaryKey ? .bold : .regular))
                .lineLimit(1)
            Text(column.rawTypeText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 120, alignment: .leading)
    }

    // MARK: 值编辑器

    @ViewBuilder
    private var valueEditor: some View {
        if isDeleted || !isEditable {
            Text(isNull ? preferences.nullDisplayText : displayText)
                .font(.system(size: 12))
                .foregroundStyle(isNull ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .italic(isNull)
        } else if isTruncatedNotLoaded, !column.kind.isBinaryLike {
            truncatedEditor
        } else if column.kind.isBinaryLike {
            binaryEditor
        } else if column.kind == .boolean, preferences.tinyInt1AsBool {
            booleanEditor()
        } else if column.kind == .enumType, let values = column.enumValues, !values.isEmpty {
            enumEditor(values: values)
        } else if column.kind == .setType, let values = column.enumValues, !values.isEmpty {
            setEditor(values: values)
        } else if column.kind.isDateTime && column.kind != .time && column.kind != .year {
            dateEditor
        } else if isMultiline {
            multilineEditor
        } else {
            textField
        }
    }

    private var isMultiline: Bool {
        column.kind == .json || (column.kind == .text && column.isLargeObject)
    }

    private var textField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: column.kind.isNumeric ? .monospaced : .default))
            .multilineTextAlignment(column.kind.isNumeric ? .trailing : .leading)
            .focused($isFocused)
            .onSubmit { commit() }
            .onExitCommand { discardDraft() }
    }

    /// 截断的大字段：先加载完整值再编辑。
    private var truncatedEditor: some View {
        HStack(spacing: 6) {
            Text(displayText + "…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.loadingFullValues.contains(row.identity) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("加载完整内容…") {
                    Task { await model.loadFullValue(row: row.identity, column: column.name) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var multilineEditor: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 48, maxHeight: 90)
                .focused($isFocused)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    commit()
                    return .handled
                }
                .onExitCommand { discardDraft() }
            HStack(spacing: 8) {
                Button("展开") { isExpanded = true }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Text("⌘↩ 提交")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var dateEditor: some View {
        HStack(spacing: 4) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($isFocused)
                .onSubmit { commit() }
                .onExitCommand { discardDraft() }
            DatePicker("", selection: dateBinding, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 120)
        }
    }

    private var dateBinding: Binding<Date> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let parsed = formatter.date(from: draft) ?? Date()
        return Binding(
            get: { parsed },
            set: { newValue in draft = formatter.string(from: newValue) }
        )
    }

    private func enumEditor(values: [String]) -> some View {
        Picker("", selection: $draft) {
            ForEach(values, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .onChange(of: draft) { _, _ in commit() }
    }

    private func setEditor(values: [String]) -> some View {
        Menu {
            ForEach(values, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { selectedSet.contains(option) },
                    set: { isOn in
                        var set = selectedSet
                        if isOn { set.insert(option) } else { set.remove(option) }
                        draft = values.filter { set.contains($0) }.joined(separator: ",")
                        commit()
                    }
                ))
            }
        } label: {
            Text(draft.isEmpty ? "（空）" : draft)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
    }

    private var selectedSet: Set<String> {
        Set(draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private func booleanEditor() -> some View {
        Picker("", selection: booleanBinding) {
            Text("NULL").tag(0)
            Text("0").tag(1)
            Text("1").tag(2)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var booleanBinding: Binding<Int> {
        Binding(
            get: {
                if value.isNull { return 0 }
                return value.displayText == "1" ? 2 : 1
            },
            set: { selection in
                switch selection {
                case 0: applyValue(.null)
                case 1: applyValue(.text("0"))
                default: applyValue(.text("1"))
                }
            }
        )
    }

    @ViewBuilder
    private var binaryEditor: some View {
        HStack(spacing: 6) {
            Text(isNull ? preferences.nullDisplayText : displayText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isNull ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("查看") { onQuickLook(row.identity, column.name) }
                .buttonStyle(.link)
                .font(.caption)
            Button("从文件导入…") { importFromFile() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var nullButton: some View {
        Button {
            guard isEditable, !isDeleted else { return }
            if isNull {
                applyValue(lastNonNull ?? .text(""))
            } else {
                lastNonNull = value
                applyValue(.null)
            }
        } label: {
            Image(systemName: isNull ? "circle.slash.fill" : "circle.slash")
                .font(.system(size: 11))
                .foregroundStyle(isNull ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("设为 NULL")
        .disabled(!isEditable || isDeleted)
    }

    // MARK: 背景 / 提示

    private var rowBackground: Color {
        if isDeleted { return Color.secondary.opacity(0.08) }
        if let change = model.pending.change(for: row.identity),
           change.kind == .update,
           change.values[column.name] != nil {
            return Color.orange.opacity(0.14)
        }
        if row.identity.isInserted, model.pending.change(for: row.identity)?.values[column.name] != nil {
            return Color.green.opacity(0.12)
        }
        return Color.clear
    }

    private var displayText: String {
        EditorDraft.string(from: value, column: column)
    }

    // MARK: 提交

    private func beginEditing() {
        guard isEditable, !isDeleted else { return }
        error = nil
        if isTruncated, model.fullValue(row: row.identity, column: column.name) == nil {
            Task { await model.loadFullValue(row: row.identity, column: column.name) }
        }
    }

    private func commit() {
        guard isEditable, !isDeleted else { return }
        // 二进制与三态复选框不走草稿文本，避免把占位串写进数据库。
        if column.kind.isBinaryLike { return }
        if column.kind == .boolean, preferences.tinyInt1AsBool { return }
        guard !isTruncated || model.fullValue(row: row.identity, column: column.name) != nil else {
            // 截断值还没加载完整：不写入，提示先加载
            Task {
                await model.loadFullValue(row: row.identity, column: column.name)
                commit()
            }
            return
        }
        let result = RowInspectorValidation.validate(draft, column: column)
        switch result {
        case .invalid(let message):
            error = message
            triggerShake()
        case .ok(let newValue):
            if isUnchanged(newValue) {
                error = nil
                return
            }
            applyValue(newValue)
        }
    }

    private func isUnchanged(_ newValue: CellValue) -> Bool {
        if row.identity.isInserted {
            if let current = model.currentValue(row: row.identity, column: column.name) {
                return current == newValue
            }
            return newValue.isNull
        }
        if let original = model.originalValue(row: row.identity, column: column.name) {
            return original == newValue
        }
        return false
    }

    private func applyValue(_ newValue: CellValue) {
        do {
            try model.applyEdit(row: row.identity, column: column.name, value: newValue)
            error = nil
            draft = EditorDraft.string(from: newValue, column: column)
        } catch let viewError as TableDataViewModelError {
            if case .truncatedValueNotLoaded = viewError {
                Task {
                    await model.loadFullValue(row: row.identity, column: column.name)
                    applyValue(newValue)
                }
            } else {
                error = viewError.message
                triggerShake()
            }
        } catch {
            self.error = String(describing: error)
            triggerShake()
        }
    }

    private func triggerShake() {
        withAnimation(.default) { shakeCount += 1 }
    }

    /// `Esc`：放弃本次输入，恢复当前值。
    private func discardDraft() {
        draft = EditorDraft.string(from: value, column: column)
        error = nil
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            applyValue(.data(data))
        } catch {
            self.error = "读取文件失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 草稿文本

enum EditorDraft {
    static func string(from value: CellValue, column: TableColumn) -> String {
        switch value {
        case .null:
            return ""
        case .bytes(let bytes):
            if column.kind.isBinaryLike {
                return GridValueFormatter.binaryPlaceholder(kind: column.kind, bytes: bytes)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

// MARK: - 抖动

struct ShakeEffect: GeometryEffect {
    var count: Int
    var travel: CGFloat = 4

    var animatableData: CGFloat {
        get { CGFloat(count) }
        set { count = Int(newValue) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = sin(CGFloat(count) * .pi) * travel
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

// MARK: - 大窗口编辑器

/// 长文本 / JSON 的展开编辑器（限高内联 + 大窗口）。
struct ExpandedTextEditorSheet: View {
    let title: String
    let text: String
    let monospaced: Bool
    var onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            TextEditor(text: $draft)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .frame(minWidth: 560, minHeight: 360)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("⌘↩ 提交 · Esc 取消")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("提交") {
                    onCommit(draft)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .onAppear { draft = text }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }
}
