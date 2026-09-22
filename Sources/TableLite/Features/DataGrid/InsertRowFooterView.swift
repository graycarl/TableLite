import SwiftUI

/// 网格底部常驻的「＋ 插入行」行（`specs/03-data-browsing.md` §1、`07-data-grid.md` §5）。
///
/// 它不属于数据行、不参与选择与滚动；不可编辑的表整行隐藏（由调用方判断）。
/// T9 会把它接到真正的「新建空白行 + 聚焦字段栏」逻辑；本阶段点击给出提示。
struct InsertRowFooterView: View {

    /// 表为空时文案改为「插入第一行」。
    let isEmptyTable: Bool
    let onInsert: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Text(isEmptyTable ? "插入第一行" : "＋ 插入行")
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture(perform: onInsert)
            .help("新建一行（编辑功能待下一任务实现）")
        }
    }
}
