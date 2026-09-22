import SwiftUI

/// 「建表语句」/「定义」页。
///
/// 等宽只读文本 + 行号；顶部 `复制`；视图上额外提供「在新查询标签中编辑」
/// （`specs/07-schema-view.md` §2.5、§3）。
///
/// 语法高亮留给查询编辑器的统一高亮实现（T11），这里先纯等宽文本。
struct SchemaDefinitionPage: View {
    let viewModel: TableStructureViewModel
    let structure: TableStructure

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            definition
        }
    }

    // MARK: 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            if viewModel.isObjectDefinitionTab {
                Text("\(viewModel.database).\(viewModel.objectName)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("复制") {
                viewModel.copyDefinition()
            }
            .disabled(viewModel.isEmptyDefinition)

            if viewModel.isView {
                Button("在新查询标签中编辑") {
                    viewModel.editDefinitionInNewQuery()
                }
                .disabled(viewModel.isEmptyDefinition)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: 语句

    @ViewBuilder
    private var definition: some View {
        if let sql = structure.createStatement, !sql.isEmpty {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let lines = sql.components(separatedBy: "\n")
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(index + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 40, alignment: .trailing)
                                .padding(.trailing, 10)
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            SchemaEmptyState(icon: "doc.plaintext", text: "没有可显示的定义语句")
        }
    }
}
