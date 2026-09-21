import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 表结构标签
//
// 只读的表结构视图：列 / 索引 / 外键 / 触发器 / 建表语句（视图只有 列 / 定义 两页）。
// 设计依据：specs/07-schema-view.md、specs/02-workspace.md §7、specs/12-feedback.md §6 §7、
// docs/tech-designs/11-schema-and-import-export.md §1。
//
// 契约：工作区外壳以 `TableStructureTabView(session:tab:environment:)` 创建（见 TabContentView）。
// ViewModel 由本视图用 `@StateObject` 持有，并在 `.onAppear` 里挂到 `tab`，供状态栏 / 重连刷新读取。
struct TableStructureTabView: View {

    let session: ConnectionSession
    let tab: Tab
    let environment: AppEnvironment

    @StateObject private var model: TableStructureViewModel
    @ObservedObject private var preferences: PreferencesStore

    init(session: ConnectionSession, tab: Tab, environment: AppEnvironment) {
        self.session = session
        self.tab = tab
        self.environment = environment
        self._preferences = ObservedObject(wrappedValue: environment.preferences)

        let ref: TableRef
        if case .tableStructure(let value) = tab.kind {
            ref = value
        } else {
            logger.error("TableStructureTabView 收到了非表结构标签，按空视图处理")
            ref = TableRef(database: "", table: "")
        }
        _model = StateObject(wrappedValue: TableStructureViewModel(ref: ref,
                                                                   meta: session.meta,
                                                                   isReadOnly: session.isReadOnly))
    }

    var body: some View {
        VStack(spacing: 0) {
            if tab.isStale {
                WorkspaceStaleBanner { Task { await refresh() } }
            }

            if model.structure != nil {
                sectionPicker
                Divider()
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // 装配回 `Tab`，供状态栏 / 重连刷新读取。
            let model = self.model
            tab.tableStructure = model
            tab.reloadAfterReconnect = { await model.refresh() }
        }
        .task {
            await model.load()
        }
        // `⌘R` 由工作区隐藏按钮直接调用 `TableStructureViewModel.refresh()`（不经本视图），
        // 因此这里监听加载结束来清除「可能过期」。失败时保留提示条。
        .onChange(of: model.isLoading) { _, isLoading in
            if !isLoading, model.loadError == nil {
                tab.isStale = false
            }
        }
    }

    // MARK: 子页签

    private var sectionPicker: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.selectedSection) {
                ForEach(model.availableSections) { section in
                    Text(section.displayName).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560, alignment: .leading)

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let structure = model.structure {
            sectionContent(structure)
        } else if let error = model.loadError {
            WorkspaceLoadErrorView(error: error) {
                Task { await refresh() }
            }
        } else {
            StructureLoadingSkeleton()
        }
    }

    @ViewBuilder
    private func sectionContent(_ structure: TableStructure) -> some View {
        switch model.selectedSection {
        case .columns:
            StructureColumnsView(structure: structure)
        case .indexes:
            StructureIndexesView(structure: structure)
        case .foreignKeys:
            StructureForeignKeysView(session: session, structure: structure)
        case .triggers:
            StructureTriggersView(structure: structure)
        case .createStatement, .definition:
            StructureCreateStatementView(session: session,
                                         structure: structure,
                                         isDefinition: model.selectedSection == .definition,
                                         fontName: preferences.editorFontName,
                                         fontSize: preferences.editorFontSize,
                                         indentWidth: preferences.editorIndentWidth)
        }
    }

    // MARK: 动作

    private func refresh() async {
        await model.refresh()
        if model.loadError == nil {
            tab.isStale = false
        }
    }
}

// MARK: - 子页通用组件

/// 表结构子页每一行的单元格。宽度固定、可选等宽 / 加粗，空文本统一显示 `—`。
struct StructureCell: View {

    let text: String
    let width: CGFloat
    var bold = false
    var monospaced = false
    var alignment: Alignment = .leading
    var secondary = false

    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
            .fontWeight(bold ? .bold : .regular)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .textSelection(.enabled)
    }
}

/// 表结构子页的表头单元格。
struct StructureHeaderCell: View {

    let title: String
    let width: CGFloat
    var alignment: Alignment = .leading

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

/// 子页无内容时的空状态（specs/12-feedback.md §6）。
struct StructureEmptyView: View {

    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
    }
}

/// 首次读取结构时的骨架占位（specs/12-feedback.md §6：骨架而不是转圈）。
struct StructureLoadingSkeleton: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(0..<8), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 16)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
