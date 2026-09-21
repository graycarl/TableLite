import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 对象定义标签

/// 视图 / 对象的只读定义页。
///
/// 内容来自 `ObjectDefinitionViewModel`（`SHOW CREATE TABLE` / `SHOW CREATE VIEW`）。
/// 顶栏提供 `复制` 与 `在新查询标签中编辑` 两个入口（`specs/07-schema-view.md` §3）。
/// 执行过 DDL 后 `tab.isStale` 为真，顶部显示「可能过期」提示条 + 刷新。
struct ObjectDefinitionTabView: View {

    let session: ConnectionSession
    let tab: Tab
    let environment: AppEnvironment

    @StateObject private var viewModel: ObjectDefinitionViewModel
    @EnvironmentObject private var toasts: ToastCenter

    init(session: ConnectionSession, tab: Tab, environment: AppEnvironment) {
        self.session = session
        self.tab = tab
        self.environment = environment
        let resolved = Self.resolve(tab: tab)
        _viewModel = StateObject(wrappedValue: ObjectDefinitionViewModel(ref: resolved.ref,
                                                                        kind: resolved.kind,
                                                                        meta: session.meta))
    }

    var body: some View {
        VStack(spacing: 0) {
            if tab.isStale {
                WorkspaceStaleBanner { Task { await refresh() } }
            }
            toolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // 装配回 `Tab`，供状态栏 / 重连刷新读取。
            let model = viewModel
            tab.objectDefinition = model
            tab.reloadAfterReconnect = { await model.refresh() }
            await model.load()
        }
    }

    // MARK: 顶栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(viewModel.kind == .view ? "视图定义" : "对象定义")
                .font(.headline)
            Spacer()
            Button("复制") { copyDefinition() }
                .disabled(viewModel.definition == nil)
                .help("复制定义原文")
            Button("在新查询标签中编辑") { editInNewQueryTab() }
                .disabled(viewModel.definition == nil)
                .help("把定义原文填进一个新的查询标签")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.definition == nil && viewModel.error == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.error, viewModel.definition == nil {
            WorkspaceLoadErrorView(error: error) {
                Task { await refresh() }
            }
        } else if let definition = viewModel.definition, !definition.isEmpty {
            ScrollView {
                Text(definition)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } else {
            Text("没有可显示的定义")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 动作

    private func refresh() async {
        await viewModel.refresh()
        tab.isStale = false
    }

    private func copyDefinition() {
        guard let definition = viewModel.definition else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(definition, forType: .string)
        toasts.show("已复制定义")
    }

    private func editInNewQueryTab() {
        guard let definition = viewModel.definition, !definition.isEmpty else { return }
        session.newQueryTab(initialSQL: definition)
    }

    // MARK: 私有

    private static func resolve(tab: Tab) -> (ref: TableRef, kind: DatabaseObjectKind) {
        if case .objectDefinition(let ref, let kind) = tab.kind {
            return (ref, kind)
        }
        logger.error("ObjectDefinitionTabView 收到了非对象定义标签，按空视图处理")
        return (TableRef(database: "", table: ""), .view)
    }
}
