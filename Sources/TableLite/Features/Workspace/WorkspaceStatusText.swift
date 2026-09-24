import Foundation

/// 连接信息文案的纯逻辑（`specs/02-workspace.md` §2、`docs/tech-designs/05-session-management.md` §10）。
///
/// 抽成纯函数便于单测；视图只负责套颜色与图标。
///
/// 界面已经在 2026-09-24 去掉底部状态栏（见 `13-open-questions.md`）：连接信息改到工具栏
/// 连接切换器的悬停详情，只读标记则跟连接切换器 / 连接列表同一套措辞。
enum WorkspaceStatusText {

    /// 只读段的文字，含前导分隔符（`specs/09-readonly-mode.md` §3：连接信息末尾追加 `· 只读`）。
    ///
    /// 单独抽成常量，供调用方把只读段与连接信息主体分开着色；
    /// `connectionLine` 与 `connectionLineParts` 共用它，避免两处措辞漂移。
    static let readOnlyMarker = "· 只读"

    /// 连接区分段结果：`body` 是连接信息主体，`readOnlyMarker` 非空时
    /// 需在末尾以醒目样式展示（`specs/09-readonly-mode.md` §3、`specs/12-feedback.md` §7）。
    struct ConnectionLineParts: Equatable {
        var body: String
        var readOnlyMarker: String?
    }

    /// 连接信息：`本地开发 · app_dev · MySQL 8.0.36 · utf8mb4 · 只读`。
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

    /// 同 `connectionLine`，但把只读段拆出来，便于调用方只给只读段套醒目颜色。
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
    /// 用于测试面板的 SSH 步骤副标题（`specs/01-connections.md` §3）与工具栏连接切换器的
    /// 悬停详情（`specs/10-ssh-tunnel.md` §4）；主界面正文不显示本地端口，避免干扰。
    static func tunnelDetailLine(host: String, port: UInt16) -> String {
        "本地转发端口 \(host):\(port)"
    }

    /// 工具栏连接切换器的悬停详情（多行）。
    ///
    /// 第一行是连接信息（只读时结尾追加 `· 只读`），启用 SSH 隧道时中间插一行本地转发端口
    /// （`specs/10-ssh-tunnel.md` §4：主界面正文不显示本地端口，只在悬停详情里显示），
    /// 最后一行是操作提示。
    static func connectionTooltip(lineParts: ConnectionLineParts, tunnelLine: String?) -> String {
        var lines = [lineParts.readOnlyMarker.map { "\(lineParts.body) \($0)" } ?? lineParts.body]
        if let tunnelLine {
            lines.append(tunnelLine)
        }
        lines.append("点击切换连接")
        return lines.joined(separator: "\n")
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
    /// `QueryEditorView` 的内部状态栏用它拼结果概要。
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
}
