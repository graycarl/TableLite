import SwiftUI

/// 表数据标签的内容视图。
///
/// 组合：过滤栏占位（T10）→ 数据网格（AppKit）→ 插入行脚 → 分页栏。
/// 右侧字段栏由 `WorkspaceView` 渲染，读的是 `tab.content` 里的同一个 ViewModel。
/// T9 在这里挂上预览 / 提交失败 / 放弃确认 / 快速查看的呈现。
struct TableDataTabView: View {

    let session: ConnectionSession
    let tab: Tab

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel: TableDataViewModel?
    @State private var quickLook: QuickLookPanelController?

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
                if viewModel.isCommitting {
                    committingOverlay(viewModel)
                }
                if viewModel.isColumnFilterPresented {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { viewModel.dismissColumnFilter() }
                    ColumnFilterPanel(
                        columns: viewModel.columns,
                        hidden: viewModel.hiddenColumns,
                        onApply: { hidden in
                            viewModel.applyColumnVisibility(hidden: hidden)
                            viewModel.dismissColumnFilter()
                        },
                        onCancel: { viewModel.dismissColumnFilter() }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isMetadataLoaded, viewModel.isEditable {
                InsertRowFooterView(isEmptyTable: viewModel.rows.isEmpty) {
                    viewModel.beginInsert()
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
        .sheet(isPresented: previewBinding(viewModel)) {
            PreviewSQLSheet(viewModel: viewModel) {
                viewModel.dismissPreview()
            }
        }
        .sheet(isPresented: commitFailureBinding(viewModel)) {
            if let failure = viewModel.commitFailure {
                CommitFailureSheet(failure: failure) {
                    viewModel.dismissCommitFailure()
                    Task { await viewModel.discardChanges() }
                } onClose: {
                    viewModel.dismissCommitFailure()
                }
            }
        }
        .confirmationDialog(
            "有未提交的修改",
            isPresented: discardBinding(viewModel),
            titleVisibility: .visible
        ) {
            Button("放弃修改", role: .destructive) {
                Task { await viewModel.discardChanges() }
            }
            Button("取消", role: .cancel) {
                viewModel.cancelDiscardConfirmation()
            }
        } message: {
            Text("确定要放弃当前标签里这 \(viewModel.pendingCount) 处未提交的修改吗？")
        }
        .onChange(of: viewModel.quickLookRequest) { _, content in
            guard let content else { return }
            presentQuickLook(content)
            viewModel.clearQuickLookRequest()
        }
    }

    /// 提交过程中的进度遮罩（`specs/04-data-editing.md` §10：界面上锁定编辑）。
    private func committingOverlay(_ viewModel: TableDataViewModel) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在提交 \(viewModel.commitCompleted)/\(viewModel.commitTotal)…")
                .font(.callout)
            Button("取消") { viewModel.cancelCommit() }
                .controlSize(.small)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func overlay(for viewModel: TableDataViewModel) -> some View {
        switch viewModel.loadState {
        case .failed(let message):
            errorOverlay(message: message, viewModel: viewModel)
        case .loading where viewModel.rows.isEmpty && viewModel.insertionRows.isEmpty:
            // 首次读取：骨架占位，不用转圈（`specs/12-feedback.md` §6）。
            GridSkeletonView()
        case .loading:
            // 翻页 / 排序 / 过滤：保留旧数据，叠一层半透明加载遮罩。
            ZStack {
                Color(nsColor: .textBackgroundColor).opacity(0.45)
                ProgressView()
                    .controlSize(.small)
            }
        case .loaded where viewModel.rows.isEmpty && viewModel.insertionRows.isEmpty:
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

    // MARK: 绑定

    private func previewBinding(_ viewModel: TableDataViewModel) -> Binding<Bool> {
        Binding(
            get: { viewModel.isPreviewPresented },
            set: { if !$0 { viewModel.dismissPreview() } }
        )
    }

    private func commitFailureBinding(_ viewModel: TableDataViewModel) -> Binding<Bool> {
        Binding(
            get: { viewModel.commitFailure != nil },
            set: { if !$0 { viewModel.dismissCommitFailure() } }
        )
    }

    private func discardBinding(_ viewModel: TableDataViewModel) -> Binding<Bool> {
        Binding(
            get: { viewModel.isDiscardConfirmationPresented },
            set: { if !$0 { viewModel.cancelDiscardConfirmation() } }
        )
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

/// 覆盖在网格上的居中提示（空表 / 失败）。
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

/// 首次加载的骨架占位（`specs/12-feedback.md` §6）。
private struct GridSkeletonView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            skeletonRow(emphasized: true)
            Divider()
            ForEach(0..<8, id: \.self) { index in
                skeletonRow(emphasized: false)
                if index < 7 {
                    Divider()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func skeletonRow(emphasized: Bool) -> some View {
        HStack(spacing: 14) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(emphasized ? 0.24 : 0.12))
                    .frame(height: emphasized ? 12 : 10)
            }
        }
        .padding(.vertical, 8)
    }
}
