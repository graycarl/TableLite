import SwiftUI

/// 表数据标签的内容视图（P4 数据网格）。
///
/// 组合：过滤栏占位（T10）→ 数据网格（AppKit）→ 插入行脚 → 分页栏。
/// 右侧字段栏由 `WorkspaceView` 渲染，读的是 `tab.content` 里的同一个 ViewModel。
struct TableDataTabView: View {

    let session: ConnectionSession
    let tab: Tab

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel: TableDataViewModel?
    @State private var quickLook: QuickLookPanelController?
    @State private var showEditNotReady = false

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                VStack {
                    ProgressView()
                    Text("正在准备表数据视图…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear(perform: startIfNeeded)
        .onDisappear {
            viewModel?.cancelInFlight()
            // 解开 Tab ↔ ViewModel 的强引用环，标签关闭后能释放。
            if let model = viewModel, tab.content === model {
                tab.content = nil
            }
        }
        .alert("编辑功能待下一任务实现", isPresented: $showEditNotReady) {
            Button("好", role: .cancel) {}
        } message: {
            Text("新建 / 修改 / 删除行会在编辑任务中提供。")
        }
    }

    // MARK: 主体

    private func content(_ viewModel: TableDataViewModel) -> some View {
        VStack(spacing: 0) {
            FilterBarView(viewModel: viewModel)

            ZStack {
                DataGridView(viewModel: viewModel, preferences: environment.preferences) { content in
                    presentQuickLook(content)
                }
                overlay(for: viewModel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isMetadataLoaded, viewModel.isEditable {
                InsertRowFooterView(isEmptyTable: viewModel.rows.isEmpty) {
                    showEditNotReady = true
                }
            }

            PaginationBarView(viewModel: viewModel)
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
    private func overlay(for viewModel: TableDataViewModel) -> some View {
        switch viewModel.loadState {
        case .failed(let message):
            errorOverlay(message: message, viewModel: viewModel)
        case .loading where viewModel.rows.isEmpty:
            StatusOverlay { ProgressView("正在加载…") }
        case .loaded where viewModel.rows.isEmpty:
            StatusOverlay {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("这张表还没有数据")
                        .foregroundStyle(.secondary)
                }
            }
        default:
            EmptyView()
        }
    }

    private func errorOverlay(message: String, viewModel: TableDataViewModel) -> some View {
        StatusOverlay {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                Text("加载表数据失败")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("重试") {
                    Task { await viewModel.refresh() }
                }
            }
            .padding(20)
        }
    }

    // MARK: 生命周期

    private func startIfNeeded() {
        guard viewModel == nil else { return }
        let model = TableDataViewModel(
            session: session,
            tab: tab,
            preferences: environment.preferences,
            clock: environment.clock
        )
        viewModel = model
        tab.content = model
        tab.reloadAfterReconnect = { [weak model] in
            await model?.refresh()
        }
        Task { await model.start() }
    }

    private func presentQuickLook(_ content: QuickLookContent) {
        if let quickLook {
            quickLook.present(content)
            return
        }
        let controller = QuickLookPanelController()
        quickLook = controller
        controller.present(content)
    }
}

/// 覆盖在网格上的居中提示（空表 / 加载中 / 失败）。
private struct StatusOverlay<Content: View>: View {

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
