import SwiftUI
import AppKit

/// 右侧字段栏：表数据标签里**唯一**的编辑入口
/// （`specs/03-data-browsing.md` §7、`specs/04-data-editing.md` §3、`docs/tech-designs/14-row-inspector.md`）。
///
/// 网格只读（S14）；这里的每个字段行按列类型选择编辑器，失焦 / `↩` 写入暂存区，`Esc` 放弃。
struct RowInspectorView: View {

    let viewModel: TableDataViewModel

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(AppColor.inspector)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.panel")
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("字段")
                    .font(AppFont.body)
                    .fontWeight(.semibold)
                Text(countText)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if showsSearch {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索字段", text: $searchText)
                        .accessibilityIdentifier("inspector.search")
                        .textFieldStyle(.plain)
                        .font(AppFont.caption)
                        .focused($searchFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                        .accessibilityIdentifier("inspector.search.clear")
                    }
                }
                .padding(.horizontal, AppSpacing.xs)
                .padding(.vertical, AppSpacing.xxs)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AppRadius.s))
            }

            if let reason = readOnlyReason {
                HStack(spacing: 6) {
                    Image(systemName: "lock")
                    Text(reason)
                        .lineLimit(2)
                    Spacer()
                }
                .font(AppFont.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, InspectorMetrics.textInset)
        .padding(.vertical, AppSpacing.xs)
    }

    /// 字段少的时候不摆搜索框；开始搜索后即使字段不多也保留输入框，避免搜到一半消失。
    private var showsSearch: Bool {
        viewModel.columns.count > 10 || !searchText.isEmpty || searchFocused
    }

    private var countText: String {
        if searchText.isEmpty {
            return "\(viewModel.columns.count) 个"
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
        // 只用一次派生结果：循环里不再重复求值 `filteredColumns`（搜过词时它是 O(列数) 的过滤）。
        let columns = filteredColumns

        return VStack(spacing: 0) {
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
                    ForEach(columns.indices, id: \.self) { index in
                        let column = columns[index]
                        InspectorFieldRow(viewModel: viewModel, row: row, column: column)
                            .id("\(row.id)#\(column.name)")

                        // 字段之间的分隔线（`14-row-inspector.md` §9）：最后一个字段下面不画。
                        if index < columns.count - 1 {
                            // 通栏（`14-row-inspector.md` §9）：和标题下面那条 `Divider()` 同宽。
                            Rectangle()
                                .fill(AppColor.rowSeparator)
                                .frame(height: 1)
                        }
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
        .padding(.horizontal, InspectorMetrics.textInset)
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
        .padding(.horizontal, InspectorMetrics.textInset)
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

/// 字段栏的左右基线（`14-row-inspector.md` §9）：文字统一落在 `textInset`，
/// 编辑器胶囊外框落在 `rowInset`，两者之差就是编辑器内边距。
private enum InspectorMetrics {
    /// 文字（标题 / 字段名 / 值）离面板边缘的距离。
    static let textInset = AppSpacing.l
    /// 编辑器胶囊外框离面板边缘的距离；胶囊内边距 = textInset - rowInset。
    static let rowInset = AppSpacing.xs
    static let fieldPadding = textInset - rowInset
}

/// 一个字段行：上面是字段名行（字段名 + 右端的类型与 `∅`），下面是占满整宽的值行
/// （`docs/tech-designs/14-row-inspector.md` §9）。
struct InspectorFieldRow: View {

    let viewModel: TableDataViewModel
    let row: GridRow
    let column: ColumnInfo

    @State private var draft: String = ""
    @State private var errorMessage: String?
    @State private var previousNonNull: SQLValue?
    @State private var isExpanded = false
    /// `NSTextView` 没有 `@FocusState`，多行编辑器的焦点由它自己回调（见 `PlainTextView`）。
    @State private var isMultilineActive = false
    /// L29：大窗口里的查找请求计数。
    @State private var findToken = 0
    @FocusState private var isFocused: Bool

    private var editorKind: FieldEditorKind {
        FieldEditorResolver.kind(for: column, tinyintAsCheckbox: viewModel.cellDisplayContext.tinyintAsCheckbox)
    }

    /// 数字 / 日期时间 / 二进制的数字串只开**等宽数字**：换 `design: .monospaced`（SF Mono）
    /// 会让左边距比 SF Pro 多约 2pt，值和文本的左缘就对不齐（`specs/03-data-browsing.md` §7）。
    private var usesTabularDigits: Bool {
        switch editorKind {
        case .number, .temporal, .binary: return true
        default: return false
        }
    }

    private var valueFont: Font {
        let base = Font.system(size: 13)
        return usesTabularDigits ? base.monospacedDigit() : base
    }

    /// `NULL` 值统一走这一份占位：灰色斜体，所有类型（含二进制）都长一样。
    private var nullPlaceholder: some View {
        Text("NULL")
            .font(.system(size: 13))
            .italic()
            .foregroundStyle(.tertiary)
            .allowsHitTesting(false)
    }

    private var currentValue: SQLValue {
        viewModel.inspectorValue(rowID: row.id, column: column.name)
    }

    private var isNullValue: Bool { currentValue.isNull }
    private var isDeleted: Bool { viewModel.isRowDeleted(rowID: row.id) }
    private var isEditable: Bool { viewModel.isEditingEnabled && !isDeleted }
    private var isEdited: Bool { viewModel.isCellEdited(rowID: row.id, column: column.name) }
    /// 本字段是否有焦点（单行靠 `@FocusState`，多行靠 `NSTextView` 回调）。
    private var isFocusedOrEditing: Bool { isFocused || isMultilineActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            labelLine

            editor
                .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, InspectorMetrics.rowInset)
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.xs)
        .background(rowBackground)
        .overlay(alignment: .topLeading) {
            if isEdited {
                Image(systemName: "arrowtriangle.up.left.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .offset(x: 1, y: 1)
            }
        }
        .onAppear(perform: syncDraft)
        .onChange(of: currentValue) { _, newValue in
            if !newValue.isNull { previousNonNull = newValue }
            if !isFocusedOrEditing { draft = FieldEditValidator.text(from: currentValue) }
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

    /// 字段名行：小字、次要色的字段名 + 右端的类型与 `∅`。
    /// 左侧留出与值编辑器内边距相同的 6pt，让字段名与值的**文字**左缘对齐。
    private var labelLine: some View {
        HStack(spacing: AppSpacing.xxs) {
            if column.isPrimaryKey {
                Image(systemName: "key.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(column.name)
                .font(.system(size: 11, weight: column.isPrimaryKey ? .bold : .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: AppSpacing.xs)
            Text(column.typeDisplayText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            nullButton
        }
        .padding(.leading, InspectorMetrics.fieldPadding)
    }

    /// 整条「面」的底色只表示「已修改」，字段行没有任何悬停底色（`14-row-inspector.md` §9）。
    /// 不做圆角卡片，聚焦也不复制一份整条高亮，交给值编辑器自己的白底与描边。
    private var rowBackground: Color {
        isEdited ? Color.orange.opacity(0.14) : .clear
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
            .textFieldStyle(.plain)
            .font(valueFont)
            .padding(.horizontal, InspectorMetrics.fieldPadding)
            .padding(.vertical, AppSpacing.xxs)
            .background(fieldBackground, in: RoundedRectangle(cornerRadius: AppRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.s)
                    .stroke(fieldBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .leading) {
                if isNullValue && draft.isEmpty {
                    nullPlaceholder
                        .padding(.horizontal, InspectorMetrics.fieldPadding)
                        .padding(.vertical, AppSpacing.xxs)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if isEditable { isFocused = true } }
            .foregroundStyle(isEditable ? Color.primary : Color.secondary)
            .disabled(!isEditable)
            .focused($isFocused)
            .onSubmit(commitDraft)
            .onChange(of: isFocused) { oldValue, newValue in
                if oldValue, !newValue { commitDraft() }
            }
            .help(column.gridTypeTooltip)
    }

    /// 值只有**聚焦**才出输入框外观：悬停就摆出白底 + 描边，看着像已经进入编辑。
    private var fieldBackground: Color {
        guard isEditable, isFocused else { return .clear }
        return Color(nsColor: .textBackgroundColor)
    }

    private var fieldBorder: Color {
        guard isEditable else { return .clear }
        if errorMessage != nil { return .red }
        return isFocused ? .accentColor : .clear
    }

    private var multilineEditor: some View {
        VStack(alignment: .leading, spacing: 3) {
            PlainTextView(
                text: $draft,
                isEditable: isEditable,
                isMultiline: true,
                fontSize: 13,
                // 字段栏里的长文本跟正文同一套字体与左缘（`14-row-inspector.md` §9）。
                usesMonospacedFont: false,
                horizontalTextInset: 0,
                showsVerticalScroller: false,
                onCommit: commitDraft,
                onCancel: cancelEdit,
                onFocusChange: { isMultilineActive = $0 }
            )
            .padding(.horizontal, InspectorMetrics.fieldPadding)
            // 按内容长高（一行内容就一行高），超过上限才在框内滚动。
            .frame(height: multilineHeight)
            .background(
                isFocusedOrEditing ? Color(nsColor: .textBackgroundColor) : Color.clear,
                in: RoundedRectangle(cornerRadius: AppRadius.s)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.s)
                    .stroke(isFocusedOrEditing ? Color.accentColor : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topLeading) {
                if isNullValue && draft.isEmpty {
                    nullPlaceholder
                        .padding(.horizontal, InspectorMetrics.fieldPadding)
                        .padding(.vertical, AppSpacing.xxs)
                }
            }
            .disabled(!isEditable)

            // 只在编辑时摆出来：不聚焦时这一行纯占高度，空值字段会空出一大块。
            if isFocusedOrEditing {
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
                .font(valueFont)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .disabled(!isEditable)
    }

    private var binaryEditor: some View {
        HStack(spacing: AppSpacing.xs) {
            if isNullValue {
                nullPlaceholder
            } else {
                Text(binaryDisplayText)
                    .font(valueFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button("查看") { viewModel.requestQuickLook(rowID: row.id, column: column.name) }
                .controlSize(.small)
                .disabled(isNullValue)
            Button("从文件导入…", action: importBinaryFile)
                .controlSize(.small)
                .disabled(!isEditable)
        }
        // 和单行编辑器同一套内边距：值的左缘才能与其它字段对齐。
        .padding(.horizontal, InspectorMetrics.fieldPadding)
        .padding(.vertical, AppSpacing.xxs)
    }

    /// 固定占位、只改轻重（`14-row-inspector.md` §9）：槽位一直有字形，
    /// 右端才只有一条停靠线；现身 / 消失会让类型的右缘和胶囊的右缘来回摇摆。
    private var nullButton: some View {
        Button(action: toggleNull) {
            Text("∅")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 16, height: 14)
                .background(nullButtonBackground, in: RoundedRectangle(cornerRadius: AppRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.s)
                        .stroke(nullButtonStroke, lineWidth: 1)
                )
                .foregroundStyle(nullButtonForeground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.plain` 不会自动变灰：只读行里不能看起来还能点。
        .opacity(isEditable ? 1 : 0.35)
        // 不参与键盘焦点环：它只是字段名行上的一个附属按钮。
        .focusable(false)
        .disabled(!isEditable)
        .accessibilityLabel(isNullValue ? "恢复为上一个非 NULL 值" : "设为 NULL")
        .help(isNullValue ? "恢复为上一个非 NULL 值" : "设为 NULL")
    }

    private var nullButtonForeground: Color {
        if isNullValue { return .accentColor }
        if isFocusedOrEditing { return .secondary }
        return Color.secondary.opacity(0.45)
    }

    private var nullButtonBackground: Color {
        if isNullValue { return Color.accentColor.opacity(0.16) }
        if isFocusedOrEditing { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var nullButtonStroke: Color {
        isNullValue ? Color.accentColor.opacity(0.55) : .clear
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
        // 新增行：Esc 取消整行（`specs/04-data-editing.md` §4）；已有行：只放弃当前字段草稿。
        if viewModel.isInsertionRow(rowID: row.id) {
            viewModel.undoRow(rowID: row.id)
            return
        }
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

    /// 多行字段的高度：按当前文本在面板里实际能占的宽度量出来，夹在 [一行, 上限] 之间
    /// （`specs/03-data-browsing.md` §7）。`NSTextView` 自己不报高度，交给 SwiftUI 侧量。
    private var multilineHeight: CGFloat {
        let width = max(viewModel.preferences.inspectorWidth - InspectorMetrics.textInset * 2, 80)
        let font = NSFont.systemFont(ofSize: 13)
        let measured = (draft.isEmpty ? " " : draft) as NSString
        let bounding = measured.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let needed = Int(ceil(bounding.height / max(lineHeight, 1)))
        // 一行内容就一行高；上限三行，再长就让「展开」去大窗口，字段栏不该被一个字段撑满。
        let lines = min(max(needed, 1), 3)
        return CGFloat(lines) * lineHeight + AppSpacing.xxs * 2
    }

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
