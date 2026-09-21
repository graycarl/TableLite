import AppKit
import SwiftUI

// MARK: - 结构 · 建表语句 / 定义
//
// specs/07-schema-view.md §2.5 §3：完整显示数据库返回的建表语句，等宽 + 语法高亮；
// 顶部 `复制`；对象是视图时页签叫「定义」，内容为创建视图的完整语句，并额外提供
// `在新查询标签中编辑`（把定义原文填进一个新的查询标签，用户改完自己执行）。
//
// 复用查询编辑器的只读文本视图（`SQLEditorView`）以获得与编辑器一致的高亮。

struct StructureCreateStatementView: View {

    let session: ConnectionSession
    let structure: TableStructure
    let isDefinition: Bool
    let fontName: String
    let fontSize: Double
    let indentWidth: Int

    @EnvironmentObject private var toasts: ToastCenter
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var cursorLocation = 0

    private var statement: String { structure.createStatement }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if statement.isEmpty {
                StructureEmptyView(message: isDefinition ? "没有可显示的定义" : "没有可显示的建表语句")
            } else {
                SQLEditorView(
                    text: .constant(statement),
                    selectedRange: $selectedRange,
                    cursorLocation: $cursorLocation,
                    fontName: fontName,
                    fontSize: fontSize,
                    indentWidth: indentWidth,
                    showLineNumbers: false,
                    highlightCurrentStatement: false,
                    isEditable: false,
                    onExecute: {},
                    onExecuteAll: {},
                    onStop: {}
                )
            }
        }
    }

    // MARK: 顶栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(isDefinition ? "定义" : "建表语句")
                .font(.headline)
            Spacer()
            Button("复制") { copyStatement() }
                .disabled(statement.isEmpty)
                .help("复制原文")
            if isDefinition {
                Button("在新查询标签中编辑") { editInNewQueryTab() }
                    .disabled(statement.isEmpty)
                    .help("把定义原文填进一个新的查询标签")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 动作

    private func copyStatement() {
        guard !statement.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(statement, forType: .string)
        toasts.show(isDefinition ? "已复制定义" : "已复制建表语句")
    }

    private func editInNewQueryTab() {
        guard !statement.isEmpty else { return }
        session.newQueryTab(initialSQL: statement)
    }
}
