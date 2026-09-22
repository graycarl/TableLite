import SwiftUI

/// 单个结果标签的内容（`docs/tech-designs/10-query-editor.md` §6）。
struct QueryResultDetailView: View {

    let result: QueryResultTab
    let displayContext: CellDisplayContext
    let fontSize: Double
    let alternateRowColors: Bool
    var onQuickLook: (QuickLookContent) -> Void
    /// 「导出结果…」入口（`specs/08-import-export.md` §1）。
    var onExport: () -> Void

    var body: some View {
        switch result.kind {
        case .resultSet:
            resultSetContent
        case .affected:
            affectedContent
        case .failure:
            failureContent
        case .blocked:
            blockedContent
        }
    }

    @ViewBuilder
    private var resultSetContent: some View {
        if result.rows.isEmpty {
            ResultStatusPanel(symbol: "tray", tint: .secondary, title: result.emptyResultText)
        } else {
            QueryResultGridView(
                columns: result.columns,
                rows: result.rows,
                displayContext: displayContext,
                fontSize: fontSize,
                alternateRowColors: alternateRowColors,
                onQuickLook: onQuickLook,
                onExport: onExport
            )
            // 切换结果标签时强制重建 NSTableView，避免复用上一标签的列 / 行与列显隐状态。
            .id(result.id)
        }
    }

    private var affectedContent: some View {
        ResultStatusPanel(
            symbol: "checkmark.circle",
            tint: .green,
            title: result.affectedSummary,
            detail: result.statementText
        )
    }

    private var failureContent: some View {
        ResultErrorPanel(
            // 面板标题与结果标签 / specs 统一为「错误」（specs/06-query-editor.md §4、manual/06 图 6-4）。
            title: "错误",
            tint: .red,
            codeLine: result.error?.codeLine,
            explanation: result.error?.chineseExplanation,
            statement: result.statementText,
            rawOutput: result.error?.message
        )
    }

    private var blockedContent: some View {
        ResultErrorPanel(
            title: "只读拦截",
            tint: .red,
            message: result.blockedReason ?? QueryResultTab.readOnlyBlockedMessage,
            statement: result.statementText
        )
    }
}

// MARK: - 面板

/// 影响行数 / 空结果的状态面板。
struct ResultStatusPanel: View {

    let symbol: String
    let tint: Color
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(tint)
            Text(title)
                .font(.title3)
            if let detail {
                Text(detail)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 错误 / 拦截面板：错误码行 + 中文解释 + 出错语句；原始服务器原文收进「查看详细输出」。
struct ResultErrorPanel: View {

    let title: String
    let tint: Color
    /// 错误码与 SQLSTATE 行（`specs/12-feedback.md` §5 规则 2，格式见 `MySQLError.codeLine`）。
    var codeLine: String?
    /// 面板主体的一句话（只读拦截用它显示被拦原因）。
    var message: String?
    var explanation: String?
    var statement: String?
    /// 服务器原文，默认折叠在「查看详细输出」后（`specs/12-feedback.md` §5 规则 4）。
    var rawOutput: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }
            if let codeLine, !codeLine.isEmpty {
                Text(codeLine)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let message, !message.isEmpty {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let explanation {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let statement, !statement.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("语句")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(statement)
                        .font(.system(.callout, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
            }
            if let rawOutput, !rawOutput.isEmpty {
                ErrorDetailDisclosure(text: rawOutput)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
