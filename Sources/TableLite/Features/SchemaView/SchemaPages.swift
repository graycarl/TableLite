import SwiftUI

// MARK: - 子页签栏

/// 结构视图顶部的子页签（`specs/07-schema-view.md` §2）。
///
/// 只做信息展示，纯 SwiftUI，不下沉 AppKit。
struct SchemaPageTabBar: View {
    let pages: [SchemaStructurePage]
    @Binding var selection: SchemaStructurePage
    let title: (SchemaStructurePage) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(pages) { page in
                Button {
                    selection = page
                } label: {
                    // 下划线用 overlay：不把按钮撑成柔性宽度，页签保持自然宽度左对齐。
                    Text(title(page))
                        .font(.callout)
                        .foregroundStyle(page == selection ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 7)
                        .padding(.bottom, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(page == selection ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == selection ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.leading, AppSpacing.xxs)
        .background(.bar)
    }
}

// MARK: - 列

/// 「列」页。主键列整行加粗并带淡蓝底；表的注释显示在顶部（`specs/07-schema-view.md` §2.1）。
struct SchemaColumnsPage: View {
    let viewModel: TableStructureViewModel
    let structure: TableStructure

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
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
                        SchemaHeaderCell(text: "字符集 / 排序规则")
                        SchemaHeaderCell(text: "备注")
                    }

                    ForEach(Array(structure.columns.enumerated()), id: \.element.id) { index, column in
                        SwiftUI.GridRow {
                            SchemaCell(text: column.ordinalPosition.map { String($0) } ?? String(index + 1))
                            SchemaCell(text: column.name, mono: true)
                            SchemaCell.value(column.columnTypeText ?? column.dataType, mono: true)
                            SchemaCell(text: column.isNullable == true ? "是" : "否")
                            SchemaCell.value(SchemaDisplay.defaultDisplay(column), mono: true)
                            SchemaCell(text: SchemaDisplay.check(column.isPrimaryKey))
                            SchemaCell(text: SchemaDisplay.check(column.isAutoIncrement))
                            SchemaCell.value(SchemaDisplay.charsetDisplay(column), mono: true)
                            SchemaCell.value(column.comment)
                        }
                        .fontWeight(column.isPrimaryKey ? .semibold : .regular)
                        .background(SchemaRowStyle.background(index: index, isPrimaryKey: column.isPrimaryKey))
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let comment = viewModel.tableComment {
                Text("表注释：\(comment)")
                    .font(.callout)
                    .lineLimit(1)
            } else {
                Text("表注释：\(SchemaDisplay.placeholder)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
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
