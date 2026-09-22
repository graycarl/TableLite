import SwiftUI

/// 列过滤器浮层（`specs/05-filtering.md` §2、`docs/tech-designs/09-filtering.md` §2）。
///
/// `⌥⌘F` 打开：按勾选控制网格显示哪些列。
/// - **纯显示行为**：不影响 SQL，隐藏的列照样会被查询；
/// - 至少保留一列可见，否则「应用」禁用并给出提示；
/// - 列显隐与列宽一起持久化（由 ViewModel 走 `TableLayout`）。
struct ColumnFilterPanel: View {

    let columns: [ColumnInfo]
    let onApply: (Set<String>) -> Void
    let onCancel: () -> Void

    @State private var workingHidden: Set<String>
    @State private var search = ""

    init(
        columns: [ColumnInfo],
        hidden: Set<String>,
        onApply: @escaping (Set<String>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.columns = columns
        self.onApply = onApply
        self.onCancel = onCancel
        _workingHidden = State(initialValue: hidden)
    }

    private var filtered: [ColumnInfo] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return columns }
        return columns.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var visibleCount: Int { columns.count - workingHidden.count }
    private var canApply: Bool { visibleCount >= 1 }

    var body: some View {
        VStack(spacing: 0) {
            Text("显示的列")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                TextField("搜索列…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("全选") { workingHidden.removeAll() }
                    .controlSize(.small)
                Button("全不选") {
                    // 至少保留一列可见。
                    workingHidden = Set(columns.dropFirst().map(\.name))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { column in
                        Toggle(isOn: binding(for: column.name)) {
                            HStack(spacing: 6) {
                                if column.isPrimaryKey {
                                    Image(systemName: "key.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(column.name)
                                    .font(.system(.callout, design: .monospaced))
                                Spacer()
                                Text(typeLabel(column))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                    }
                    if filtered.isEmpty {
                        Text("没有匹配的列")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
                .padding(.vertical, 6)
            }

            Divider()

            HStack(spacing: 10) {
                if !canApply {
                    Text("至少保留一列可见")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") { onApply(workingHidden) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
            }
            .padding(12)
        }
        .frame(width: 380, height: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.35)))
        .shadow(radius: 24)
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { !workingHidden.contains(name) },
            set: { visible in
                if visible {
                    workingHidden.remove(name)
                } else {
                    workingHidden.insert(name)
                }
            }
        )
    }

    private func typeLabel(_ column: ColumnInfo) -> String {
        column.columnTypeText ?? column.dataType ?? ""
    }
}
