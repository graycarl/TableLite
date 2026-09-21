import AppKit
import SwiftUI

// MARK: - 结构 · 索引
//
// specs/07-schema-view.md §2.2：索引名 / 类型 / 包含列（按顺序，desc 标注）/ 基数 / 备注。

struct StructureIndexesView: View {

    let structure: TableStructure

    private let nameWidth: CGFloat = 200
    private let typeWidth: CGFloat = 90
    private let columnsWidth: CGFloat = 380
    private let cardinalityWidth: CGFloat = 110
    private let commentWidth: CGFloat = 240

    var body: some View {
        if structure.indexes.isEmpty {
            StructureEmptyView(message: "没有索引")
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    ForEach(structure.indexes) { index in
                        row(index)
                        Divider()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            StructureHeaderCell(title: "索引名", width: nameWidth)
            StructureHeaderCell(title: "类型", width: typeWidth)
            StructureHeaderCell(title: "包含的列", width: columnsWidth)
            StructureHeaderCell(title: "基数", width: cardinalityWidth, alignment: .trailing)
            StructureHeaderCell(title: "备注", width: commentWidth)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ index: TableIndex) -> some View {
        let isPrimary = index.indexType.uppercased() == "PRIMARY"
        return HStack(spacing: 0) {
            StructureCell(text: index.name, width: nameWidth, bold: isPrimary, monospaced: true)
            StructureCell(text: index.displayType, width: typeWidth, bold: isPrimary)
            StructureCell(text: columnList(index),
                          width: columnsWidth,
                          bold: isPrimary,
                          monospaced: true)
            StructureCell(text: index.cardinality.map { String($0) } ?? "",
                          width: cardinalityWidth,
                          bold: isPrimary,
                          alignment: .trailing,
                          secondary: true)
            StructureCell(text: index.comment ?? "", width: commentWidth, bold: isPrimary)
        }
        .background(isPrimary ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    /// 按索引内顺序列出列名，降序列标注 `desc`。
    private func columnList(_ index: TableIndex) -> String {
        index.columns
            .map { $0.descending ? "\($0.name) desc" : $0.name }
            .joined(separator: ", ")
    }
}
