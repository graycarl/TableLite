import Foundation

/// 状态栏文案的纯逻辑（`specs/02-workspace.md` §7、`docs/tech-designs/05-session-management.md` §10）。
///
/// 抽成纯函数便于单测；视图只负责套颜色与图标。
enum WorkspaceStatusText {

    /// 状态栏只读段的文字，含前导分隔符（`specs/09-readonly-mode.md` §3：连接信息末尾追加 `· 只读`）。
    ///
    /// 单独抽成常量，供状态栏把只读段与连接信息主体分开着色；
    /// `connectionLine` 与 `connectionLineParts` 共用它，避免两处措辞漂移。
    static let readOnlyMarker = "· 只读"

    /// 状态栏连接区分段结果：`body` 是连接信息主体，`readOnlyMarker` 非空时
    /// 需在末尾以醒目样式展示（`specs/09-readonly-mode.md` §3、`specs/12-feedback.md` §7）。
    struct ConnectionLineParts: Equatable {
        var body: String
        var readOnlyMarker: String?
    }

    /// 状态栏连接区：`● 本地开发 · app_dev · MySQL 8.0.36 · utf8mb4 · 只读`。
    static func connectionLine(
        connection: Connection,
        state: SessionConnectionState,
        database: String?,
        serverInfo: ServerInfo?,
        isReadOnly: Bool
    ) -> String {
        let parts = connectionLineParts(
            connection: connection,
            state: state,
            database: database,
            serverInfo: serverInfo,
            isReadOnly: isReadOnly
        )
        guard let marker = parts.readOnlyMarker else { return parts.body }
        return "\(parts.body) \(marker)"
    }

    /// 同 `connectionLine`，但把只读段拆出来，便于状态栏只给只读段套醒目颜色。
    ///
    /// 主界面正文不显示本地端口，只读标识与连接列表 / 切换器保持同一套措辞。
    static func connectionLineParts(
        connection: Connection,
        state: SessionConnectionState,
        database: String?,
        serverInfo: ServerInfo?,
        isReadOnly: Bool
    ) -> ConnectionLineParts {
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

        return ConnectionLineParts(
            body: parts.joined(separator: " · "),
            readOnlyMarker: isReadOnly ? readOnlyMarker : nil
        )
    }

    /// 隧道信息行：`本地转发端口 127.0.0.1:53142`。
    ///
    /// 用于测试面板的 SSH 步骤副标题（`specs/01-connections.md` §3）与状态栏的悬停详情
    /// （`specs/10-ssh-tunnel.md` §4）；主界面正文不显示本地端口，避免干扰。
    static func tunnelDetailLine(host: String, port: UInt16) -> String {
        "本地转发端口 \(host):\(port)"
    }

    // MARK: 加载耗时（`specs/12-feedback.md` §6）

    /// 网络慢于该时长才在网格底部条显示耗时。
    static let slowQueryThresholdMilliseconds = 1_000
    /// 慢于该时长在网格底部条文字后附「取消」按钮。
    static let cancellableQueryThresholdMilliseconds = 10_000

    /// 表数据网格底部条左侧摘要：基础文本 + 超时耗时。
    ///
    /// 耗时只在 **> 1 秒** 时追加，避免每次重新加载都闪一个「12 ms」
    /// （`specs/12-feedback.md` §6）。基础文本由 `TableDataViewModel.rowCountBarText`
    /// 提供，耗时口径统一在这里，不在 ViewModel 里重复拼接。
    static func tableDataSummary(base: String, elapsedMilliseconds: Int?) -> String {
        guard let milliseconds = elapsedMilliseconds,
              milliseconds > slowQueryThresholdMilliseconds else { return base }
        return "\(base) · \(milliseconds) ms"
    }

    /// 是否显示「取消」按钮（`specs/12-feedback.md` §6：超过 10 秒）。
    static func showsCancelButton(elapsedMilliseconds: Int) -> Bool {
        elapsedMilliseconds > cancellableQueryThresholdMilliseconds
    }

    /// 查询编辑器状态栏摘要：`已执行 3 条语句 · 耗时 42 ms · 返回 1,204 行`。
    ///
    /// 尚未执行任何语句时返回 nil，由调用方决定占位文案；
    /// `QueryEditorView` 的内部状态栏与窗口底部状态栏共用这一份拼接逻辑。
    static func querySummary(
        executedStatementCount: Int,
        elapsedMilliseconds: Int,
        totalReturnedRows: Int
    ) -> String? {
        guard executedStatementCount > 0 else { return nil }
        var parts: [String] = ["已执行 \(executedStatementCount) 条语句"]
        if elapsedMilliseconds > 0 {
            parts.append("耗时 \(elapsedMilliseconds) ms")
        }
        if totalReturnedRows > 0 {
            // 千位分隔符与显示条数栏 / manual 图 2-7 保持一致（`1,204 行`）。
            parts.append("返回 \(RowCountEstimate.grouped(Int64(totalReturnedRows))) 行")
        }
        return parts.joined(separator: " · ")
    }

    /// Console Log 工具栏计数（`manual/06-query-editor.html` 图 6-6：`保留最近 5000 条`）。
    ///
    /// 保留条数与当前可见条数一起显示，不丢失原有的条数信息。
    static func consoleLogCountLabel(count: Int, capacity: Int) -> String {
        "\(count) 条 · 保留最近 \(capacity) 条"
    }

    /// 状态栏标签区的兜底文案。表数据 / 查询 / 结构的真实摘要由各自 ViewModel 提供，
    /// 这里只覆盖标签尚未装配 ViewModel 或没有专属摘要的情况。
    static func tabSummary(for kind: TabKind, rowLimit: RowLimitState?, consoleLogCount: Int) -> String {
        switch kind {
        case .tableData:
            if let rowLimit {
                return "最多 \(rowLimit.limit) 行"
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
