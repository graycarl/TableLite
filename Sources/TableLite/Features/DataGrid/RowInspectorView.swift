import SwiftUI
import AppKit

/// 右侧字段栏：表数据标签里**唯一**的编辑入口
/// （`specs/03-data-browsing.md` §7、`specs/04-data-editing.md` §3、`docs/tech-designs/14-row-inspector.md`）。
///
/// 网格只读（S14）；这里的每个字段行按列类型选择编辑器，失焦 / `↩` 写入暂存区，`Esc` 放弃。
struct RowInspectorView: View {

    let viewModel: TableDataViewModel

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索字段", text: $searchText)
                    .textFieldStyle(.plain)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let reason = readOnlyReason {
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                    Text(reason)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var countText: String {
        if searchText.isEmpty {
            return "\(viewModel.columns.count) 个字段"
        }
        return "显示 \(filteredColumns.count) / \(viewModel.columns.count)"
    }

    private var readOnlyReason: String? {
        guard viewModel.isMetadataLoaded, !viewModel.isEditable else { return nil }
        return viewModel.editability.reason?.message
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.selectedRowIDs.count > 1 {
            message("已选中 \(viewModel.selectedRowIDs.count) 行 · 请只选一行")
        } else if let row = viewModel.inspectorRow {
            fieldList(for: row)
        } else {
            message("选中一行以查看和编辑它的字段")
        }
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fieldList(for row: GridRow) -> some View {
        VStack(spacing: 0) {
            rowBanner(for: row)

            if viewModel.isLoadingFullRow {
                statusBar(text: "正在加载完整内容…", systemImage: "arrow.down.circle")
            } else if let error = viewModel.fullRowError {
                statusBar(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
            } else if viewModel.manualFullLoadRequired {
                manualLoadBar
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredColumns) { column in
                        InspectorFieldRow(viewModel: viewModel, row: row, column: column)
                            .id("\(row.id)#\(column.name)")
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowBanner(for row: GridRow) -> some View {
        if viewModel.isRowDeleted(rowID: row.id) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                Text("这一行已标记删除")
                Spacer()
                Button("撤销删除") { viewModel.undoDeletion(rowID: row.id) }
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.red.opacity(0.08))
        } else if viewModel.isInsertionRow(rowID: row.id) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                Text("新增行")
                Spacer()
                Button("取消这一行") { viewModel.undoRow(rowID: row.id) }
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.08))
        }
    }

    private func statusBar(text: String, systemImage: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.08))
    }

    private var manualLoadBar: some View {
        HStack(spacing: 6) {
            Button("加载完整内容…") {
                viewModel.requestFullRowLoad(force: true)
            }
            .controlSize(.small)
            Text("该行大字段合计超过 8 MB")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.08))
    }

    private var filteredColumns: [ColumnInfo] {
        guard !searchText.isEmpty else { return viewModel.columns }
        let needle = searchText.lowercased()
        return viewModel.columns.filter { $0.name.lowercased().contains(needle) }
    }
}

// MARK: - 字段行

/// 一个字段行：列名（主键加粗 + 🔑）、类型（灰小字）、按列类型选择的编辑器、`∅` 按钮。
struct InspectorFieldRow: View {

    let viewModel: TableDataViewModel
    let row: GridRow
    let column: ColumnInfo

    @State private var draft: String = ""
    @State private var errorMessage: String?
    @State private var previousNonNull: SQLValue?
    @State private var isExpanded = false
    /// L29：大窗口里的查找请求计数。
    @State private var findToken = 0
    @FocusState private var isFocused: Bool

    private var editorKind: FieldEditorKind {
        FieldEditorResolver.kind(for: column, tinyintAsCheckbox: viewModel.cellDisplayContext.tinyintAsCheckbox)
    }

    private var currentValue: SQLValue {
        viewModel.inspectorValue(rowID: row.id, column: column.name)
    }

    private var isNullValue: Bool { currentValue.isNull }
    private var isDeleted: Bool { viewModel.isRowDeleted(rowID: row.id) }
    private var isEditable: Bool { viewModel.isEditingEnabled && !isDeleted }
    private var isEdited: Bool { viewModel.isCellEdited(rowID: row.id, column: column.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if column.isPrimaryKey { Text("🔑") }
                Text(column.name)
                    .fontWeight(column.isPrimaryKey ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(column.typeDisplayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 6) {
                editor
                nullButton
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isEdited ? Color.orange.opacity(0.16) : Color.clear)
        .overlay(alignment: .topLeading) {
            if isEdited {
                Image(systemName: "arrowtriangle.up.left.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .offset(x: 2, y: 2)
            }
        }
        .onAppear(perform: syncDraft)
        .onChange(of: currentValue) { _, newValue in
            if !newValue.isNull { previousNonNull = newValue }
            if !isFocused { draft = FieldEditValidator.text(from: currentValue) }
        }
        .onChange(of: viewModel.focusRequestToken) { _, _ in
            if viewModel.focusRequestColumn == column.name, isEditable {
                isFocused = true
            }
        }
        .onExitCommand(perform: cancelEdit)
        .sheet(isPresented: $isExpanded) {
            expandedEditor
        }
    }

    // MARK: 编辑器

    @ViewBuilder
    private var editor: some View {
        switch editorKind {
        case .binary:
            binaryEditor

        case .booleanTinyInt:
            Toggle("", isOn: Binding(
                get: { currentValue == .bool(true) || currentValue == .text("1") },
                set: { commit(value: .bool($0)) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEditable)

        case .enumeration(let values):
            Picker("", selection: Binding(
                get: { draft },
                set: { newValue in
                    draft = newValue
                    commitDraft()
                }
            )) {
                Text("（空）").tag("")
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .disabled(!isEditable)

        case .set(let values):
            setEditor(values)

        case .multilineText:
            multilineEditor

        case .number, .temporal, .singleLineText:
            singleLineEditor
        }
    }

    private var singleLineEditor: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: editorKind == .number ? .monospaced : .default))
            .multilineTextAlignment(editorKind == .number ? .trailing : .leading)
            .disabled(!isEditable)
            .focused($isFocused)
            .onSubmit(commitDraft)
            .onChange(of: isFocused) { oldValue, newValue in
                if oldValue, !newValue { commitDraft() }
            }
            .help(column.gridTypeTooltip)
    }

    private var multilineEditor: some View {
        VStack(alignment: .leading, spacing: 3) {
            PlainTextView(
                text: $draft,
                isEditable: isEditable,
                isMultiline: true,
                fontSize: 12,
                onCommit: commitDraft,
                onCancel: cancelEdit
            )
            .frame(minHeight: 56, maxHeight: 120)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            .disabled(!isEditable)

            HStack(spacing: 6) {
                Button("展开") { isExpanded = true }
                    .controlSize(.small)
                Text("⇧↩ 换行 · ⌘↩ 提交")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func setEditor(_ values: [String]) -> some View {
        let selected = Set(draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        Menu {
            ForEach(values, id: \.self) { value in
                Button {
                    toggleSetValue(value, values: values)
                } label: {
                    HStack {
                        Text(value)
                        if selected.contains(value) { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Text(draft.isEmpty ? "（空）" : draft)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .disabled(!isEditable)
    }

    private var binaryEditor: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(binaryDisplayText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))

            HStack(spacing: 6) {
                Button("查看") { viewModel.requestQuickLook(rowID: row.id, column: column.name) }
                    .controlSize(.small)
                Button("从文件导入…", action: importBinaryFile)
                    .controlSize(.small)
                    .disabled(!isEditable)
                Spacer()
            }
        }
    }

    private var nullButton: some View {
        Button {
            toggleNull()
        } label: {
            Text("∅").frame(width: 18)
        }
        .buttonStyle(.bordered)
        .tint(isNullValue ? Color.accentColor : Color.secondary)
        .controlSize(.small)
        .disabled(!isEditable)
        .help(isNullValue ? "恢复为上一个非 NULL 值" : "设为 NULL")
    }

    // MARK: 提交 / 取消

    private func syncDraft() {
        draft = FieldEditValidator.text(from: currentValue)
        if !currentValue.isNull { previousNonNull = currentValue }
        errorMessage = nil
    }

    private func commitDraft() {
        guard isEditable else { return }
        if let error = FieldEditValidator.validate(text: draft, column: column, kind: editorKind) {
            errorMessage = error.message
            isFocused = true
            return
        }
        errorMessage = nil
        let value = FieldEditValidator.value(fromText: draft, column: column, kind: editorKind)
        commit(value: value)
    }

    private func commit(value: SQLValue) {
        guard isEditable else { return }
        if !value.isNull { previousNonNull = value }
        Task { await viewModel.applyInspectorEdit(rowID: row.id, column: column.name, value: value) }
    }

    private func cancelEdit() {
        draft = FieldEditValidator.text(from: currentValue)
        errorMessage = nil
        isFocused = false
    }

    private func toggleNull() {
        if isNullValue {
            commit(value: previousNonNull ?? .text(""))
        } else {
            previousNonNull = currentValue
            commit(value: .null)
        }
    }

    private func toggleSetValue(_ value: String, values: [String]) {
        var members = Set(draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        if members.contains(value) {
            members.remove(value)
        } else {
            members.insert(value)
        }
        // 保持表定义里的顺序，输出确定。
        draft = values.filter { members.contains($0) }.joined(separator: ",")
        commitDraft()
    }

    private func importBinaryFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        commit(value: .binary(data))
    }

    // MARK: 展示

    private var binaryDisplayText: String {
        let display = CellDisplayFormatter.display(
            value: currentValue,
            isTruncated: false,
            totalByteCount: row.cells[column.name]?.totalByteCount,
            column: column,
            context: viewModel.cellDisplayContext
        )
        return display.text
    }

    private var expandedEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(column.name) · \(column.typeDisplayText)")
                    .font(.headline)
                Spacer()
                Button("查找") { findToken += 1 }
                    .help("在内容里查找（⌘F 面板）")
                Button("完成") {
                    commitDraft()
                    isExpanded = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            // L29：大窗口带行号与查找；内容不是 SQL，关掉语法着色。
            SQLTextView(
                text: $draft,
                isEditable: isEditable,
                fontSize: 13,
                showLineNumbers: true,
                highlightCurrentStatement: false,
                syntaxHighlighting: false,
                findRequestToken: findToken
            )
            .frame(minWidth: 560, minHeight: 360)
        }
    }
}
