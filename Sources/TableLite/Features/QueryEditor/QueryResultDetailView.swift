import SwiftUI

/// 单个结果标签的内容（`docs/tech-designs/10-query-editor.md` §6）。
struct QueryResultDetailView: View {

    let result: QueryResultTab
    let displayContext: CellDisplayContext
    let fontSize: Double
    let alternateRowColors: Bool
    var onQuickLook: (QuickLookContent) -> Void

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
                onQuickLook: onQuickLook
            )
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
            title: "执行失败",
            tint: .red,
            message: result.error.map { "\($0.code)：\($0.message)" } ?? "未知错误",
            explanation: result.error?.chineseExplanation,
            statement: result.statementText
        )
    }

    private var blockedContent: some View {
        ResultErrorPanel(
            title: "只读拦截",
            tint: .orange,
            message: result.blockedReason ?? "只读模式：写操作已被禁用",
            explanation: "该连接处于只读模式，这条语句没有被下发到服务器。",
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

/// 错误 / 拦截面板：原文 + 中文解释 + 出错语句。
struct ResultErrorPanel: View {

    let title: String
    let tint: Color
    let message: String
    var explanation: String?
    var statement: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }
            Text(message)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
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
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
