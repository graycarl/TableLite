import SwiftUI

// MARK: - 子页签栏

/// 结构视图顶部的子页签（`specs/07-schema-view.md` §2）。
///
/// 只做信息展示，纯 SwiftUI，不下沉 AppKit。
struct SchemaPageTabBar: View {
    let pages: [SchemaStructurePage]
    @Binding var selection: SchemaStructurePage
    let title: (SchemaStructurePage) -> String
    var onCopyDDL: (() -> Void)?
    var copyDisabled = false

    var body: some View {
        HStack(spacing: 10) {
            if pages.count > 1 {
                Picker("结构页", selection: $selection) {
                    ForEach(pages) { page in
                        Text(title(page)).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 440, alignment: .leading)
                .accessibilityIdentifier("schema.page")
            } else if let page = pages.first {
                Text(title(page))
                    .font(AppFont.body)
                    .fontWeight(.medium)
            }

            Spacer()

            Button("复制 DDL") { onCopyDDL?() }
                .buttonStyle(.subtle)
                .controlSize(.small)
                .disabled(copyDisabled || onCopyDDL == nil)
                .help("复制建表语句 / 视图定义")
                .accessibilityIdentifier("schema.copy-ddl")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppColor.bar)
    }
}

// MARK: - 列

/// 「列」页。主键列整行加粗并带淡蓝底；表的注释显示在顶部（`specs/07-schema-view.md` §2.1）。
struct SchemaColumnsPage: View {
    let viewModel: TableStructureViewModel
    let structure: TableStructure

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasTableComment {
                header
                Divider()
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    SwiftUI.GridRow {
                        SchemaHeaderCell(text: "序号")
                        SchemaHeaderCell(text: "列名")
                        SchemaHeaderCell(text: "类型")
                        SchemaHeaderCell(text: "可空")
                        SchemaHeaderCell(text: "默认值")
                        SchemaHeaderCell(text: "主键")
                        SchemaHeaderCell(text: "自增")
                    }

                    ForEach(Array(structure.columns.enumerated()), id: \.element.id) { index, column in
                        SwiftUI.GridRow {
                            SchemaCell(text: column.ordinalPosition.map { String($0) } ?? String(index + 1))
                            SchemaCell(text: column.name, mono: true)
                                .help(columnDetail(column))
                            SchemaCell.value(column.columnTypeText ?? column.dataType, mono: true)
                            SchemaCell(text: column.isNullable == true ? "是" : "否")
                            SchemaCell.value(SchemaDisplay.defaultDisplay(column), mono: true)
                            SchemaCell(text: SchemaDisplay.check(column.isPrimaryKey))
                            SchemaCell(text: SchemaDisplay.check(column.isAutoIncrement))
                        }
                        .fontWeight(column.isPrimaryKey ? .semibold : .regular)
                        .background(SchemaRowStyle.background(index: index, isPrimaryKey: column.isPrimaryKey))
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private var hasTableComment: Bool {
        viewModel.tableComment != nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("表注释：\(viewModel.tableComment ?? "")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// 字符集 / 排序规则与列备注不再占默认列，悬停列名时显示。
    private func columnDetail(_ column: ColumnInfo) -> String {
        var parts = [column.name]
        let charset = SchemaDisplay.charsetDisplay(column)
        if charset != SchemaDisplay.placeholder {
            parts.append("字符集 / 排序规则：\(charset)")
        }
        if let comment = column.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty {
            parts.append("备注：\(comment)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 索引

/// 「索引」页（`specs/07-schema-view.md` §2.2）。
struct SchemaIndexesPage: View {
    let structure: TableStructure

    var body: some View {
        if structure.indexes.isEmpty {
            SchemaEmptyState(icon: "square.stack.3d.up.slash", text: "这张表没有索引")
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    SwiftUI.GridRow {
                        SchemaHeaderCell(text: "索引名")
                        SchemaHeaderCell(text: "类型")
                        SchemaHeaderCell(text: "包含的列")
                        SchemaHeaderCell(text: "基数")
                        SchemaHeaderCell(text: "备注")
                    }

                    ForEach(Array(structure.indexes.enumerated()), id: \.element.id) { index, indexInfo in
                        SwiftUI.GridRow {
                            SchemaCell(text: indexInfo.name, mono: true)
                            SchemaCell(text: indexInfo.kind.displayName)
                            SchemaCell.value(SchemaDisplay.indexColumnsDisplay(indexInfo), mono: true)
                            SchemaCell.value(SchemaDisplay.cardinalityDisplay(indexInfo), mono: true)
                            SchemaCell.value(indexInfo.comment)
                        }
                        .fontWeight(indexInfo.kind == .primary ? .semibold : .regular)
                        .background(SchemaRowStyle.background(index: index, isPrimaryKey: indexInfo.kind == .primary))
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }
}

// MARK: - 外键

/// 「外键」页。引用表可点击跳到那张表（`specs/07-schema-view.md` §2.3）。
struct SchemaForeignKeysPage: View {
    let viewModel: TableStructureViewModel
    let structure: TableStructure

    var body: some View {
        if structure.foreignKeys.isEmpty {
            SchemaEmptyState(icon: "link.badge.plus", text: "这张表没有外键")
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    SwiftUI.GridRow {
                        SchemaHeaderCell(text: "约束名")
                        SchemaHeaderCell(text: "本表列")
                        SchemaHeaderCell(text: "引用表")
                        SchemaHeaderCell(text: "引用列")
                        SchemaHeaderCell(text: "删除时")
                        SchemaHeaderCell(text: "更新时")
                    }

                    ForEach(Array(structure.foreignKeys.enumerated()), id: \.element.id) { index, foreignKey in
                        SwiftUI.GridRow {
                            SchemaCell(text: foreignKey.name, mono: true)
                            SchemaCell.value(SchemaDisplay.joined(foreignKey.columns), mono: true)
                            referencedTableCell(foreignKey)
                            SchemaCell.value(SchemaDisplay.joined(foreignKey.referencedColumns), mono: true)
                            SchemaCell(text: foreignKey.onDelete)
                            SchemaCell(text: foreignKey.onUpdate)
                        }
                        .background(SchemaRowStyle.background(index: index, isPrimaryKey: false))
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func referencedTableCell(_ foreignKey: ForeignKeyInfo) -> some View {
        Button {
            viewModel.openReferencedTable(foreignKey)
        } label: {
            Text(foreignKey.referencedDisplayName)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("打开 \(foreignKey.referencedDisplayName)")
    }
}

// MARK: - 触发器

/// 「触发器」页。触发器体多行折叠，点击展开（`specs/07-schema-view.md` §2.4）。
struct SchemaTriggersPage: View {
    let structure: TableStructure

    @State private var expanded: Set<String> = []

    var body: some View {
        if structure.triggers.isEmpty {
            SchemaEmptyState(icon: "bolt.slash", text: "这张表没有触发器")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    Divider()
                    ForEach(structure.triggers) { trigger in
                        triggerRow(trigger)
                        Divider()
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            SchemaHeaderCell(text: "名称").frame(width: 240, alignment: .leading)
            SchemaHeaderCell(text: "时机").frame(width: 100, alignment: .leading)
            SchemaHeaderCell(text: "事件").frame(width: 120, alignment: .leading)
            SchemaHeaderCell(text: "语句").frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func triggerRow(_ trigger: TriggerInfo) -> some View {
        let isExpanded = expanded.contains(trigger.name)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SchemaCell(text: trigger.name, mono: true).frame(width: 240, alignment: .leading)
                SchemaCell(text: trigger.timing.rawValue).frame(width: 100, alignment: .leading)
                SchemaCell(text: trigger.event.rawValue).frame(width: 120, alignment: .leading)
                Button {
                    if isExpanded {
                        expanded.remove(trigger.name)
                    } else {
                        expanded.insert(trigger.name)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                        Text(isExpanded ? "折叠" : "展开")
                            .font(.callout)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if isExpanded {
                Text(trigger.statement)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
    }
}
