import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 对象树

/// 当前库的表 / 视图对象树。见 `specs/02-workspace.md` §5。
///
/// 数据来源：`ConnectionSession.objects`（`selectedDatabase` 变化时由 `ConnectionSession`
/// 重新拉取），经 `ObjectTreeModel` 做过滤 / 分组 / 截断。视图只读状态、只发意图。
struct ObjectTreeView: View {

    @ObservedObject var session: ConnectionSession
    @ObservedObject var objectTree: ObjectTreeModel

    @EnvironmentObject private var toasts: ToastCenter
    @State private var destructiveAction: DestructiveObjectAction?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .sheet(item: $destructiveAction) { action in
            DestructiveConfirmSheet(
                action: action,
                onConfirm: {
                    destructiveAction = nil
                    Task { await perform(action) }
                },
                onCancel: { destructiveAction = nil }
            )
        }
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索表、视图…", text: $objectTree.searchText)
                .textFieldStyle(.plain)
            if !objectTree.searchText.isEmpty {
                Button { objectTree.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .textBackgroundColor)))
        .padding(8)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if session.selectedDatabase == nil {
            placeholder("请选择一个数据库")
        } else if session.isLoadingObjects && session.objects.isEmpty {
            loadingPlaceholder
        } else if objectTree.isEmpty && !objectTree.isSearching {
            placeholder("当前数据库没有表")
        } else if objectTree.hasNoMatches {
            placeholder("没有匹配的对象")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if objectTree.isTruncated {
                        Text("仅显示前 500 项，请用上方搜索框查找")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    ForEach(objectTree.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func sectionView(_ section: ObjectTreeSection) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: section.kind)) {
            if section.objects.isEmpty {
                Text("（空）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
                    .padding(.vertical, 3)
            } else {
                ForEach(section.objects) { object in
                    ObjectRow(
                        object: object,
                        isReadOnly: session.isReadOnly,
                        onAction: { action in handle(action, object: object) }
                    )
                }
            }
        } label: {
            Text("\(section.title) (\(section.totalCount))")
                .font(.system(.body, weight: .semibold))
                .padding(.vertical, 2)
        }
        .padding(.horizontal, 8)
    }

    private func expansionBinding(for kind: DatabaseObjectKind) -> Binding<Bool> {
        Binding(
            get: { objectTree.isSearching || objectTree.expandedGroups.contains(kind) },
            set: { expanded in
                if expanded {
                    objectTree.expandedGroups.insert(kind)
                } else {
                    objectTree.expandedGroups.remove(kind)
                }
            }
        )
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 12)
                    .padding(.horizontal, 12)
            }
            Spacer()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: 意图

    private func handle(_ action: ObjectRowAction, object: DatabaseObject) {
        let database = objectTree.database ?? session.selectedDatabase ?? ""
        let ref = TableRef(database: database, table: object.name)

        switch action {
        case .openData(let forceNew):
            session.openTableData(ref, forceNew: forceNew)
        case .openStructure:
            session.openTableStructure(ref)
        case .openDefinition:
            session.openObjectDefinition(ref, kind: object.kind)
        case .copyName:
            copyName(object.name)
        case .export:
            notImplemented("导出")
        case .importCSV:
            notImplemented("导入 CSV")
        case .truncate:
            destructiveAction = DestructiveObjectAction(kind: .truncate, ref: ref)
        case .drop:
            destructiveAction = DestructiveObjectAction(kind: .drop, ref: ref)
        }
    }

    private func copyName(_ name: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
        toasts.show("已复制 \(name)")
    }

    private func notImplemented(_ feature: String) {
        // TODO(Wave 5)：导出 / 导入面板由后续 wave 提供，这里先只给轻提示。
        toasts.show("\(feature)功能即将实现")
    }

    private func perform(_ action: DestructiveObjectAction) async {
        guard !session.isReadOnly else {
            toasts.show("只读模式：写操作已被禁用")
            return
        }
        let sql = action.sql
        do {
            try await session.mysql.execute(sql)
            await session.meta.invalidate(action.ref)
            await session.refreshObjects()
            toasts.show(action.successMessage)
        } catch {
            logger.error("\(action.title)失败：\(String(describing: error), privacy: .public)")
            toasts.show((error as? MySQLError)?.title ?? "操作失败")
        }
    }
}

// MARK: - 对象行

private enum ObjectRowAction {
    case openData(forceNew: Bool)
    case openStructure
    case openDefinition
    case copyName
    case export
    case importCSV
    case truncate
    case drop
}

private struct ObjectRow: View {

    let object: DatabaseObject
    let isReadOnly: Bool
    let onAction: (ObjectRowAction) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: object.kind == .table ? "tablecells" : "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(object.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            onAction(object.kind == .table ? .openData(forceNew: true) : .openDefinition)
        }
        .onTapGesture {
            onAction(object.kind == .table ? .openData(forceNew: false) : .openDefinition)
        }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if object.kind == .table {
            Button("打开数据") { onAction(.openData(forceNew: false)) }
            Button("打开结构") { onAction(.openStructure) }
            Divider()
            Button("复制表名") { onAction(.copyName) }
            Divider()
            Button("导出…") { onAction(.export) }
            Button("导入 CSV…") { onAction(.importCSV) }
                .disabled(isReadOnly)
            Divider()
            Button("截断表…") { onAction(.truncate) }
                .disabled(isReadOnly)
            Button("删除表…") { onAction(.drop) }
                .disabled(isReadOnly)
        } else {
            Button("打开定义") { onAction(.openDefinition) }
            Button("复制名称") { onAction(.copyName) }
        }
    }
}

// MARK: - 破坏性操作

private struct DestructiveObjectAction: Identifiable {

    enum Kind: String {
        case truncate
        case drop
    }

    let kind: Kind
    let ref: TableRef

    var id: String { "\(kind.rawValue)-\(ref.displayName)" }

    var title: String {
        switch kind {
        case .truncate: return "截断表"
        case .drop: return "删除表"
        }
    }

    var buttonTitle: String {
        switch kind {
        case .truncate: return "截断"
        case .drop: return "删除"
        }
    }

    var sql: String {
        switch kind {
        case .truncate:
            return "TRUNCATE TABLE \(SQLIdentifier.qualified(ref.database, ref.table));"
        case .drop:
            return "DROP TABLE \(SQLIdentifier.qualified(ref.database, ref.table));"
        }
    }

    var warning: String {
        "该操作不可撤销，且无法通过「放弃改动」回退。"
    }

    var successMessage: String {
        switch kind {
        case .truncate: return "已截断 \(ref.table)"
        case .drop: return "已删除 \(ref.table)"
        }
    }
}

private struct DestructiveConfirmSheet: View {

    let action: DestructiveObjectAction
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var canConfirm: Bool {
        input == action.ref.table
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.title).font(.headline)

            Text("将要执行：")
                .foregroundStyle(.secondary)
            Text(action.sql)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor)))

            Text(action.warning)
                .foregroundStyle(.secondary)

            Text("请输入表名 \(action.ref.table) 以确认：")

            TextField(action.ref.table, text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(action.buttonTitle, role: .destructive) { onConfirm() }
                    .disabled(!canConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { inputFocused = true }
    }
}
