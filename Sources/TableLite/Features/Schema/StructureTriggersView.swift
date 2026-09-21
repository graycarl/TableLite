import AppKit
import SwiftUI

// MARK: - 结构 · 触发器
//
// specs/07-schema-view.md §2.4：名称 / 时机 / 事件 / 语句（多行折叠显示，点击展开）。

struct StructureTriggersView: View {

    let structure: TableStructure

    private let nameWidth: CGFloat = 200
    private let timingWidth: CGFloat = 90
    private let eventWidth: CGFloat = 90
    private let statementWidth: CGFloat = 560

    var body: some View {
        if structure.triggers.isEmpty {
            StructureEmptyView(message: "没有触发器")
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    ForEach(structure.triggers) { trigger in
                        TriggerRow(trigger: trigger,
                                   nameWidth: nameWidth,
                                   timingWidth: timingWidth,
                                   eventWidth: eventWidth,
                                   statementWidth: statementWidth)
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            StructureHeaderCell(title: "名称", width: nameWidth)
            StructureHeaderCell(title: "时机", width: timingWidth)
            StructureHeaderCell(title: "事件", width: eventWidth)
            StructureHeaderCell(title: "语句", width: statementWidth)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - 触发器行

private struct TriggerRow: View {

    let trigger: TableTrigger
    let nameWidth: CGFloat
    let timingWidth: CGFloat
    let eventWidth: CGFloat
    let statementWidth: CGFloat

    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            StructureCell(text: trigger.name, width: nameWidth, monospaced: true)
            StructureCell(text: trigger.timing, width: timingWidth)
            StructureCell(text: trigger.event, width: eventWidth)
            statementCell
        }
    }

    private var statementCell: some View {
        Button {
            expanded.toggle()
        } label: {
            Text(trigger.statement.isEmpty ? "—" : trigger.statement)
                .font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.leading)
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.tail)
                .frame(width: statementWidth, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "点击折叠语句" : "点击展开语句")
    }
}
