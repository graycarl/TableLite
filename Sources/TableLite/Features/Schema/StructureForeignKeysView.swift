import AppKit
import SwiftUI

// MARK: - 结构 · 外键
//
// specs/07-schema-view.md §2.3：约束名 / 本表列 / 引用表 / 引用列 / 删除时 / 更新时；
// 引用表可点击，跳到那张表。

struct StructureForeignKeysView: View {

    let session: ConnectionSession
    let structure: TableStructure

    private let nameWidth: CGFloat = 200
    private let columnsWidth: CGFloat = 200
    private let referencedTableWidth: CGFloat = 200
    private let referencedColumnsWidth: CGFloat = 200
    private let deleteWidth: CGFloat = 120
    private let updateWidth: CGFloat = 120

    var body: some View {
        if structure.foreignKeys.isEmpty {
            StructureEmptyView(message: "没有外键")
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    ForEach(structure.foreignKeys) { constraint in
                        row(constraint)
                        Divider()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            StructureHeaderCell(title: "约束名", width: nameWidth)
            StructureHeaderCell(title: "本表列", width: columnsWidth)
            StructureHeaderCell(title: "引用表", width: referencedTableWidth)
            StructureHeaderCell(title: "引用列", width: referencedColumnsWidth)
            StructureHeaderCell(title: "删除时", width: deleteWidth)
            StructureHeaderCell(title: "更新时", width: updateWidth)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ constraint: ForeignKeyConstraint) -> some View {
        HStack(spacing: 0) {
            StructureCell(text: constraint.name, width: nameWidth, monospaced: true)
            StructureCell(text: constraint.columns.joined(separator: ", "),
                          width: columnsWidth,
                          monospaced: true)
            referencedTableCell(constraint)
            StructureCell(text: constraint.referencedColumns.joined(separator: ", "),
                          width: referencedColumnsWidth,
                          monospaced: true)
            StructureCell(text: constraint.onDelete, width: deleteWidth)
            StructureCell(text: constraint.onUpdate, width: updateWidth)
        }
    }

    /// 引用表：`库.表`，点击在新标签打开那张表的数据。
    /// 外键跳转即使目标表已打开也新建（见 App/Tab.swift 的 `forceNew` 说明）。
    private func referencedTableCell(_ constraint: ForeignKeyConstraint) -> some View {
        let ref = TableRef(database: constraint.referencedDatabase,
                           table: constraint.referencedTable)
        return Button {
            session.openTableData(ref, forceNew: true)
        } label: {
            Text(constraint.referencedDisplay)
                .font(.system(.callout, design: .monospaced))
                .frame(width: referencedTableWidth, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.link)
        .help("打开 \(constraint.referencedDisplay)")
    }
}
