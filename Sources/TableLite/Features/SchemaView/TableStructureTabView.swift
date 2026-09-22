import SwiftUI

/// 表结构 / 对象定义标签的内容视图（P9）。
///
/// 接线契约：
/// ```swift
/// TableStructureTabView(session: session, tab: tab)
/// ```
/// `TabContentView` 里 `.tableStructure` 与 `.objectDefinition` 两个分支都挂它；
/// `database` / 对象名从 `tab.kind` 里取（`docs/tech-designs/06-ui-layer.md` §3）。
///
/// 组合：过期提示条 → 子页签栏 → 当前页。
/// ViewModel 由本视图创建并写回 `tab.content`，`reloadAfterReconnect` 接重连后的刷新。
struct TableStructureTabView: View {

    let session: ConnectionSession
    let tab: Tab

    @State private var viewModel: TableStructureViewModel?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                SchemaLoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: startIfNeeded)
        .onDisappear {
            viewModel?.cancelInFlight()
            // 解开 Tab ↔ ViewModel 的强引用环，标签关闭后能释放。
            if let model = viewModel, tab.content === model {
                tab.content = nil
            }
        }
    }

    // MARK: 主体

    private func content(_ viewModel: TableStructureViewModel) -> some View {
        VStack(spacing: 0) {
            if viewModel.isStale {
                StaleStructureBanner {
                    Task { await viewModel.refresh() }
                }
                Divider()
            }

            if viewModel.pages.count > 1 {
                SchemaPageTabBar(
                    pages: viewModel.pages,
                    selection: pageSelection(viewModel),
                    title: { viewModel.pageTitle($0) }
                )
                Divider()
            }

            pageBody(viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            if let notice = viewModel.copyNotice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func pageBody(_ viewModel: TableStructureViewModel) -> some View {
        if viewModel.loadState == .failed {
            SchemaErrorView(error: viewModel.loadError) {
                Task { await viewModel.refresh() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let structure = viewModel.structure {
            page(viewModel, structure: structure)
        } else {
            SchemaLoadingView()
        }
    }

    @ViewBuilder
    private func page(_ viewModel: TableStructureViewModel, structure: TableStructure) -> some View {
        switch viewModel.selectedPage {
        case .columns:
            SchemaColumnsPage(viewModel: viewModel, structure: structure)
        case .indexes:
            SchemaIndexesPage(structure: structure)
        case .foreignKeys:
            SchemaForeignKeysPage(viewModel: viewModel, structure: structure)
        case .triggers:
            SchemaTriggersPage(structure: structure)
        case .definition:
            SchemaDefinitionPage(viewModel: viewModel, structure: structure)
        }
    }

    private func pageSelection(_ viewModel: TableStructureViewModel) -> Binding<SchemaStructurePage> {
        Binding(
            get: { viewModel.selectedPage },
            set: { viewModel.selectedPage = $0 }
        )
    }

    // MARK: 生命周期

    private func startIfNeeded() {
        guard viewModel == nil else { return }
        let model = TableStructureViewModel(session: session, tab: tab)
        viewModel = model
        tab.content = model
        tab.reloadAfterReconnect = { [weak model] in
            await model?.refresh()
        }
        Task { await model.start() }
    }
}
