import Foundation

/// 状态栏文案的纯逻辑（`specs/02-workspace.md` §7、`docs/tech-designs/05-session-management.md` §10）。
///
/// 抽成纯函数便于单测；视图只负责套颜色与图标。
enum WorkspaceStatusText {

    /// 状态栏连接区：`● 本地开发 · app_dev · MySQL 8.0.36 · utf8mb4 · 只读`。
    static func connectionLine(
        connection: Connection,
        state: SessionConnectionState,
        database: String?,
        serverInfo: ServerInfo?,
        isReadOnly: Bool
    ) -> String {
        var parts: [String] = [connection.name]

        if let database, !database.isEmpty {
            parts.append(database)
        }

        if state.isConnected, let serverInfo {
            if !serverInfo.version.isEmpty {
                parts.append("MySQL \(serverInfo.version)")
            }
            let charset = serverInfo.connectionCharset.isEmpty ? serverInfo.charset : serverInfo.connectionCharset
            if !charset.isEmpty {
                parts.append(charset)
            }
        } else {
            parts.append(state.displayText)
        }

        if isReadOnly {
            parts.append("只读")
        }
        return parts.joined(separator: " · ")
    }

    /// 状态栏标签区。本阶段表数据 / 查询 / 结构都还没有真实数据，用占位文案，
    /// 具体行数与耗时由后续 wave 填充。
    static func tabSummary(for kind: TabKind, page: PageState?, consoleLogCount: Int) -> String {
        switch kind {
        case .tableData:
            if let page {
                return "第 \(page.pageIndex + 1) 页 · \(page.pageSize) 行/页"
            }
            return "等待加载数据"
        case .tableStructure:
            return "结构待加载"
        case .objectDefinition:
            return "定义待加载"
        case .query:
            return "等待执行"
        case .history:
            return "查询历史"
        case .consoleLog:
            return "已记录 \(consoleLogCount) 条语句"
        }
    }
}
