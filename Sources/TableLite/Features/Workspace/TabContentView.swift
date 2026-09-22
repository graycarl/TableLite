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
        case .tableData:
            TableDataTabView(session: session, tab: tab)
        case .tableStructure:
            TableStructureTabView(session: session, tab: tab)
        case .objectDefinition:
            TableStructureTabView(session: session, tab: tab)
        case .query:
            QueryEditorView(session: session, tab: tab)
        case .history:
            HistoryTabView(session: session)
        case .consoleLog:
            ConsoleLogTabView()
        }
    }
}
