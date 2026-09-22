import SwiftUI

/// 后续 wave 才实现的内容标签的占位视图。
///
/// 按 `docs/tech-designs/06-ui-layer.md` §1：能用 SwiftUI 就用 SwiftUI，
/// 这里只是信息展示，不需要下沉 AppKit。
struct TabPlaceholderView: View {

    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 标签内容分派器。
///
/// 表数据 / 表结构 / 对象定义 / 查询四种标签本阶段显示占位；
/// 查询历史与 Console Log 数据已经具备，直接实现。
struct TabContentView: View {

    let session: ConnectionSession
    let tab: Tab

    var body: some View {
        switch tab.kind {
        case .tableData(let database, let table):
            TabPlaceholderView(
                symbol: "tablecells",
                title: "表数据视图",
                detail: "\(database).\(table)\n数据网格与右侧字段栏待 W3/W4 实现"
            )
        case .tableStructure(let database, let table):
            TabPlaceholderView(
                symbol: "list.bullet.rectangle",
                title: "表结构视图",
                detail: "\(database).\(table)\n列 / 索引 / 外键 / 触发器待 W4 实现"
            )
        case .objectDefinition(let database, let object):
            TabPlaceholderView(
                symbol: "doc.plaintext",
                title: "对象定义",
                detail: "\(database).\(object) 的定义语句待 W4 实现"
            )
        case .query:
            TabPlaceholderView(
                symbol: "chevron.left.forwardslash.chevron.right",
                title: "SQL 编辑器",
                detail: "查询编辑器与结果标签待 W4/W7 实现"
            )
        case .history:
            HistoryTabView(session: session)
        case .consoleLog:
            ConsoleLogTabView()
        }
    }
}
