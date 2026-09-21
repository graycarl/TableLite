import AppKit
import SwiftUI

// MARK: - 结构 · 列
//
// specs/07-schema-view.md §2.1：序号 / 列名 / 类型 / 可空 / 默认值 / 主键 / 自增 /
// 字符集·排序规则（仅文本类型）/ 备注；主键列整行加粗；表注释显示在顶部。

struct StructureColumnsView: View {

    let structure: TableStructure

    // 固定列宽，整表横向滚动。
    private let seqWidth: CGFloat = 48
    private let nameWidth: CGFloat = 180
    private let typeWidth: CGFloat = 220
    private let nullableWidth: CGFloat = 56
    private let defaultWidth: CGFloat = 160
    private let pkWidth: CGFloat = 48
    private let autoIncrementWidth: CGFloat = 48
    private let charsetWidth: CGFloat = 220
    private let commentWidth: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            if let comment = structure.comment, !comment.isEmpty {
                commentBar(comment)
                Divider()
            }
            if structure.columns.isEmpty {
                StructureEmptyView(message: "没有列")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Divider()
                        ForEach(structure.columns, id: \.name) { column in
                            row(column)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: 表头 / 行

    private var header: some View {
        HStack(spacing: 0) {
            StructureHeaderCell(title: "序号", width: seqWidth, alignment: .trailing)
            StructureHeaderCell(title: "列名", width: nameWidth)
            StructureHeaderCell(title: "类型", width: typeWidth)
            StructureHeaderCell(title: "可空", width: nullableWidth)
            StructureHeaderCell(title: "默认值", width: defaultWidth)
            StructureHeaderCell(title: "主键", width: pkWidth)
            StructureHeaderCell(title: "自增", width: autoIncrementWidth)
            StructureHeaderCell(title: "字符集 / 排序规则", width: charsetWidth)
            StructureHeaderCell(title: "备注", width: commentWidth)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ column: TableColumn) -> some View {
        let bold = column.isPrimaryKey
        return HStack(spacing: 0) {
            StructureCell(text: String(column.position),
                          width: seqWidth,
                          bold: bold,
                          alignment: .trailing,
                          secondary: true)
            StructureCell(text: column.name, width: nameWidth, bold: bold, monospaced: true)
            StructureCell(text: column.rawTypeText, width: typeWidth, bold: bold, monospaced: true)
            StructureCell(text: column.isNullable ? "是" : "否", width: nullableWidth, bold: bold)
            StructureCell(text: column.defaultValue ?? "",
                          width: defaultWidth,
                          bold: bold,
                          monospaced: true)
            StructureCell(text: column.isPrimaryKey ? "✓" : "—", width: pkWidth, bold: bold)
            StructureCell(text: column.isAutoIncrement ? "✓" : "—",
                          width: autoIncrementWidth,
                          bold: bold)
            StructureCell(text: charsetText(column),
                          width: charsetWidth,
                          bold: bold,
                          monospaced: true,
                          secondary: true)
            StructureCell(text: column.comment ?? "", width: commentWidth, bold: bold)
        }
        .background(bold ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    // MARK: 细节

    /// 字符集 / 排序规则只对文本类型有意义（specs/07 §2.1）。
    private func charsetText(_ column: TableColumn) -> String {
        guard column.kind == .text else { return "—" }
        let charset = column.charset ?? "—"
        let collation = column.collation ?? "—"
        return "\(charset) / \(collation)"
    }

    private func commentBar(_ comment: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.secondary)
            Text(comment)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
