import SwiftUI

/// 有未提交改动时贴在网格下方的上下文变更条（`specs/03-data-browsing.md` §2、
/// `docs/tech-designs/08-pending-changes.md` §8）。
///
/// 没有改动时整条不渲染；预览 / 放弃 / 提交都从这里走，工具栏不再承担变更操作。
struct PendingChangesBar: View {

    let viewModel: TableDataViewModel

    var body: some View {
        if viewModel.pendingCount > 0 {
            HStack(spacing: 8) {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .shadow(color: .orange.opacity(0.22), radius: 3)

                Text("\(viewModel.pendingCount) 处未提交")
                    .font(AppFont.secondary)
                    .fontWeight(.medium)

                Text("提交后写入数据库")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button("预览 SQL") { viewModel.presentPreview() }
                    .buttonStyle(.subtle)
                    .controlSize(.small)
                    .disabled(viewModel.isCommitting)
                    .help("预览将要执行的 SQL（⇧⌘P）")
                    .accessibilityIdentifier("grid.pending.preview")

                Button("放弃") { viewModel.requestDiscard() }
                    .buttonStyle(.subtle)
                    .controlSize(.small)
                    .disabled(viewModel.isCommitting)
                    .help("放弃全部未提交修改（⇧⌘⌫）")
                    .accessibilityIdentifier("grid.pending.discard")

                Button {
                    viewModel.requestSubmit()
                } label: {
                    Text("提交")
                    Text("⌘↩")
                        .font(.system(size: 9.5))
                        .opacity(0.75)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.isEditable || viewModel.isCommitting)
                .help(submitHint)
                .accessibilityIdentifier("grid.pending.submit")
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(
                LinearGradient(
                    colors: [Color.orange.opacity(0.10), Color.orange.opacity(0.02)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var submitHint: String {
        switch viewModel.editability.reason {
        case .readOnlyConnection: return "该连接处于只读模式，无法提交修改"
        case .view: return "视图不可编辑，无法提交修改"
        case .noPrimaryKey: return "该表没有主键，无法安全提交修改"
        case nil: return "提交修改（⌘↩）"
        }
    }
}
