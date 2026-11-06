import SwiftUI

/// 过滤生效时的一行 chips 摘要（`specs/05-filtering.md` §1）。
///
/// 只显示**已应用**的过滤条件；点 chip 打开筛选卡片，点 × 删除该条件并重新应用。
/// 没有生效条件时整行不出现，不再常驻一条筛选面板。
struct FilterChipsBar: View {

    let viewModel: TableDataViewModel
    var onEdit: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let filter = viewModel.filter, filter.isActive {
            HStack(spacing: 6) {
                Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if filter.isRawMode {
                            chip(text: rawText(filter.rawWhere), isRaw: true) {
                                clearAll()
                            }
                        } else {
                            ForEach(filter.activeConditions) { condition in
                                chip(text: condition.chipText) {
                                    remove(condition.id)
                                }
                            }
                        }
                        Button {
                            viewModel.addFilterCondition()
                            onEdit()
                        } label: {
                            Label("添加条件", systemImage: "plus")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.subtle)
                        .controlSize(.small)
                        .accessibilityIdentifier("grid.filter.add")
                    }
                }

                Spacer(minLength: 4)

                Button("清除") { clearAll() }
                    .buttonStyle(.subtle)
                    .controlSize(.small)
                    .accessibilityIdentifier("grid.filter.clear")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("grid.filter.chips")
        }
    }

    private func chip(text: String, isRaw: Bool = false, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(AppFont.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isRaw ? "清除筛选条件" : "删除这个条件")
            .accessibilityIdentifier("grid.filter.chip.remove")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.25))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("grid.filter.chip")
    }

    private func rawText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 64 ? String(trimmed.prefix(64)) + "…" : trimmed
    }

    private func remove(_ id: UUID) {
        viewModel.removeAppliedFilterCondition(id: id)
    }

    private func clearAll() {
        viewModel.clearAppliedFilter()
    }
}
