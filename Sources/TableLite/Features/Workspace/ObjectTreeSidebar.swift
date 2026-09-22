import SwiftUI
import AppKit

/// 左侧栏：库切换器 + 对象搜索 + 对象树 + 查询历史 / Console Log 入口。
///
/// 布局见 `specs/02-workspace.md` §1、§5，线框见 `manual/02-workspace.html`。
///
/// 技术选型：对象树只有「表 / 视图」两层，最多 500 项/组，用 SwiftUI
/// `ScrollView` + `LazyVStack` 足够；不为它下沉 AppKit（`06-ui-layer.md` §1）。
struct ObjectTreeSidebar: View {

    let session: ConnectionSession
    /// 外部（⌘F）要求聚焦搜索框时自增。
    let focusSearchRequest: Int
    /// 右键「导出…」（P8 接线）；nil 时菜单项禁用。
    var onExport: ((TableInfo) -> Void)?
    /// 右键「导入 CSV…」（P8 接线）；nil 时菜单项禁用。
    var onImportCSV: ((TableInfo) -> Void)?

    @State private var searchText = ""
    // nil 表示尚未从工作区状态加载，按「全部展开」渲染，避免首帧闪烁（L21）。
    @State private var expandedGroups: Set<ObjectTreeGroup>?
    @State private var pendingOperation: DestructiveTableOperation?
    @FocusState private var searchFocused: Bool

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DatabaseSwitcher(session: session)

            searchField
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            truncatedHint
            objectTree

            Divider()

            HStack(spacing: 0) {
                entryButton("查询历史", systemImage: "clock.arrow.circlepath") {
                    session.openHistoryTab()
                }
                entryButton("Console Log", systemImage: "terminal") {
                    session.openConsoleLogTab()
                }
            }
            .padding(6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: loadExpandedGroupsIfNeeded)
        .task(id: focusSearchRequest) {
            // 0 是初始值；只有显式请求（⌘F）时才聚焦，且兼容侧栏隐藏后重新创建的情况。
            if focusSearchRequest > 0 {
                searchFocused = true
            }
        }
        .sheet(item: $pendingOperation) { operation in
            DestructiveTableOperationSheet(operation: operation, session: session) {
                // `session.execute` 执行 DDL 后已自动刷新对象树，这里无需重复。
            }
        }
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索表、视图…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 提示条

    @ViewBuilder
    private var truncatedHint: some View {
        if groups.contains(where: \.isTruncated) {
            Label(ObjectTreeModel.truncationHint, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
    }

    // MARK: 对象树

    private var objectTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if session.selectedDatabase == nil {
                    emptyState("请选择一个数据库", systemImage: "cylinder.split.1x2")
                } else if !session.isLoadingObjects && session.objects.isEmpty {
                    emptyState("当前数据库没有表", systemImage: "tablecells")
                } else {
                    ForEach(groups) { group in
                        groupHeader(group)
                        if isExpanded(group.group) {
                            groupContent(group)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func groupContent(_ group: ObjectTreeGroupContent) -> some View {
        if session.isLoadingObjects && group.items.isEmpty {
            ForEach(0..<3, id: \.self) { _ in
                loadingRow
            }
        } else if group.isEmpty {
            Text("（空）")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.leading, 28)
                .padding(.vertical, 4)
        } else {
            ForEach(group.items) { object in
                objectRow(object)
            }
        }
    }

    private func groupHeader(_ group: ObjectTreeGroupContent) -> some View {
        Button {
            toggleGroup(group.group)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded(group.group) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(group.title)
                    .font(.callout.weight(.medium))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func objectRow(_ object: TableInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: object.kind == .view ? "eye" : "tablecells")
                .font(.caption)
                .foregroundStyle(object.kind == .view ? .purple : .secondary)
                .frame(width: 14)
            Text(object.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            open(object, forceNew: true)
        }
        .onTapGesture(count: 1) {
            open(object, forceNew: false)
        }
        .contextMenu {
            contextMenu(for: object)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 90, height: 10)
            Spacer()
        }
        .padding(.leading, 28)
        .padding(.vertical, 5)
    }

    // MARK: 右键菜单

    @ViewBuilder
    private func contextMenu(for object: TableInfo) -> some View {
        // 视图只读：只提供定义查看与复制名字。
        if object.kind == .view {
            Button("打开定义") { open(object, forceNew: true) }
            Button("复制名字") { copyName(object.name) }
        } else {
            Button("打开数据") { open(object, forceNew: false) }
            Button("打开结构") {
                session.openTableStructure(database: object.database, table: object.name)
            }
            Button("复制表名") { copyName(object.name) }

            Divider()

            Button("导出…") { onExport?(object) }
                .disabled(onExport == nil)
            Button("导入 CSV…") { onImportCSV?(object) }
                .disabled(onImportCSV == nil || session.isReadOnly)

            Divider()

            Button("截断表…") {
                pendingOperation = .truncate(database: object.database, table: object.name)
            }
            .disabled(session.isReadOnly)

            Button("删除表…") {
                pendingOperation = .drop(database: object.database, table: object.name)
            }
            .disabled(session.isReadOnly)
        }
    }

    // MARK: 底部入口

    private func entryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func emptyState(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: 逻辑

    private var groups: [ObjectTreeGroupContent] {
        ObjectTreeModel.group(session.objects, query: searchText)
    }

    private func isExpanded(_ group: ObjectTreeGroup) -> Bool {
        // 搜索时自动展开所有分组（`specs/02-workspace.md` §5）。
        if !searchText.isEmpty { return true }
        guard let expandedGroups else { return true }
        return expandedGroups.contains(group)
    }

    // MARK: 分组折叠状态持久化（L21）

    private func loadExpandedGroupsIfNeeded() {
        guard expandedGroups == nil else { return }
        let collapsed = environment.workspace.collapsedObjectTreeGroups
        expandedGroups = Set(ObjectTreeGroup.allCases.filter { !collapsed.contains($0.rawValue) })
    }

    private func toggleGroup(_ group: ObjectTreeGroup) {
        var current = expandedGroups ?? Set(ObjectTreeGroup.allCases)
        if current.contains(group) {
            current.remove(group)
        } else {
            current.insert(group)
        }
        expandedGroups = current
        environment.workspace.collapsedObjectTreeGroups =
            Set(ObjectTreeGroup.allCases.map(\.rawValue)).subtracting(current.map(\.rawValue))
    }

    private func open(_ object: TableInfo, forceNew: Bool) {
        switch object.kind {
        case .table:
            session.openTableData(database: object.database, table: object.name, forceNew: forceNew)
        case .view:
            session.openObjectDefinition(database: object.database, object: object.name, forceNew: forceNew)
        }
    }

    private func copyName(_ name: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
    }
}
