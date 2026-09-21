import SwiftUI

// MARK: - 提交失败
//
// 失败序号 + 原始错误（不翻译、不截断）+ 该语句 + 数据状态说明。
// 见 specs/12-feedback.md §5、specs/04-data-editing.md §10。

struct CommitErrorSheet: View {
    let failure: CommitFailure
    var onDiscardAll: () -> Void
    var onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var stateMessage: String {
        if failure.transactionStateUnknown {
            return "提交超时，事务状态未知，请在数据库中手动核对这几行的数据。"
        }
        if failure.rolledBack {
            return "事务已回滚，你的修改都还在暂存区里，尚未生效。"
        }
        return "事务状态未知，请在数据库中手动核对这几行的数据。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("提交失败")
                .font(.headline)
            Text("第 \(failure.statementIndex) 条语句执行失败")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("[错误 \(failure.error.code)] SQLSTATE \(failure.error.sqlState)")
                    .font(.system(size: 12, design: .monospaced))
                if !failure.error.message.isEmpty {
                    Text(failure.error.message)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                if let hint = failure.error.chineseHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(failure.statement)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(stateMessage)
                .font(.system(size: 12))

            HStack {
                Spacer()
                Button("放弃全部修改") {
                    onDiscardAll()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("关闭并修正") {
                    onClose()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
    }
}
