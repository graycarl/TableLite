import SwiftUI

// MARK: - 纯格式化函数

/// 结构视图里各列 / 单元格的显示规则。全部是纯函数，便于单测。
///
/// 体现 `specs/07-schema-view.md` §2 的边界：
/// - 没有默认值显示 `—`，默认值为 `NULL` 才显示 `NULL`；
/// - 字符集 / 排序规则仅文本类型显示，其余显示 `—`；
/// - 索引列按顺序列出，前缀长度与 `desc` 明确标注。
enum SchemaDisplay {

    static let placeholder = "—"

    /// 空值统一显示为 `—`。
    static func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return placeholder }
        return value
    }

    static func check(_ value: Bool) -> String {
        value ? "✓" : ""
    }

    /// 默认值：`hasDefaultValue` 为假（数据库返回 NULL 的 `COLUMN_DEFAULT`）→ `—`；
    /// 有默认值但取不到文本 → `NULL`。
    static func defaultDisplay(_ column: ColumnInfo) -> String {
        guard column.hasDefaultValue == true else { return placeholder }
        guard let value = column.columnDefault else { return "NULL" }
        if value.isEmpty { return "''" }
        return value
    }

    /// 字符集 / 排序规则：只对带字符集的文本类型显示。
    static func charsetDisplay(_ column: ColumnInfo) -> String {
        guard let charset = column.characterSet, !charset.isEmpty else { return placeholder }
        if let collation = column.collation, !collation.isEmpty {
            return "\(charset) / \(collation)"
        }
        return charset
    }

    /// 索引包含的列：`` `name` `` + 前缀长度 + `desc`，按索引定义顺序。
    static func indexColumnsDisplay(_ index: IndexInfo) -> String {
        index.columns.map { column in
            var text = "`\(column.name)`"
            if let prefix = column.prefixLength {
                text += "(\(prefix))"
            }
            if column.isDescending {
                text += " desc"
            }
            return text
        }
        .joined(separator: ", ")
    }

    static func joined(_ names: [String]) -> String {
        names.isEmpty ? placeholder : names.joined(separator: ", ")
    }

    static func cardinalityDisplay(_ index: IndexInfo) -> String {
        guard let cardinality = index.cardinality else { return placeholder }
        return String(cardinality)
    }
}

// MARK: - 网格基础样式

/// 结构视图里的表格行底色：主键行淡蓝、其余隔行浅灰。
enum SchemaRowStyle {
    static func background(index: Int, isPrimaryKey: Bool) -> Color {
        if isPrimaryKey { return Color.accentColor.opacity(0.10) }
        return index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035)
    }
}

/// 表头单元格。
struct SchemaHeaderCell: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// 数据单元格。`mono` 用于列名 / 类型 / SQL 等，`secondary` 用于 `—` 这类占位。
struct SchemaCell: View {
    let text: String
    var mono: Bool = false
    var secondary: Bool = false

    var body: some View {
        Text(text)
            .font(mono ? .system(.callout, design: .monospaced) : .callout)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .textSelection(.enabled)
    }

    /// 从原始值构造：空值自动落到 `—` 的次要样式。
    static func value(_ raw: String?, mono: Bool = false) -> SchemaCell {
        if let raw, !raw.isEmpty {
            return SchemaCell(text: raw, mono: mono)
        }
        return SchemaCell(text: SchemaDisplay.placeholder, mono: mono, secondary: true)
    }
}

// MARK: - 空状态 / 加载 / 错误

/// 页内空状态（`specs/12-feedback.md` §6：明确说明「没有数据」）。
struct SchemaEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 首次读取结构时的占位。用骨架条而不是转圈图标（`specs/12-feedback.md` §6）。
struct SchemaLoadingView: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 90, height: 10)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: row.isMultiple(of: 2) ? 150 : 110, height: 10)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(SchemaRowStyle.background(index: row, isPrimaryKey: false))
            }
            Spacer()
        }
    }
}

/// 结构加载失败的错误面板（`specs/12-feedback.md` §5）。
struct SchemaErrorView: View {
    let error: SchemaLoadError?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("加载表结构失败")
                .font(.headline)
            Text(error?.message ?? "（没有错误详情）")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)

            if let error {
                if error.code != nil || error.sqlState != nil {
                    Text(errorCodeLine(error))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let statement = error.statement, !statement.isEmpty {
                    Text(statement)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }

            Button("重试", action: onRetry)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 460)
    }

    private func errorCodeLine(_ error: SchemaLoadError) -> String {
        var parts: [String] = []
        if let code = error.code { parts.append("[错误 \(code)]") }
        if let sqlState = error.sqlState, !sqlState.isEmpty { parts.append("SQLSTATE \(sqlState)") }
        return parts.joined(separator: " ")
    }
}

/// 结构可能过期的顶部提示条（`specs/07-schema-view.md` §4、`specs/12-feedback.md` §7）。
struct StaleStructureBanner: View {
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("这张表的结构可能已经改变，显示的内容可能不是最新的。")
                .font(.callout)
            Spacer()
            Button("刷新", action: onRefresh)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }
}
