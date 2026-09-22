import AppKit
import SwiftUI

/// 导出面板。入口契约：
/// ```swift
/// .sheet(item: $exportSource) { source in
///     ExportPanelView(session: session, source: source) { summary in ... }
/// }
/// ```
///
/// 面板自管尺寸与关闭（`@Environment(\.dismiss)`），完成后通过 `onFinish` 回调。
/// 需求见 `specs/08-import-export.md` §1；大表内存平稳的硬约束在 `CSVExportEngine`。
struct ExportPanelView: View {

    let session: ConnectionSession
    let source: ExportSource
    var onFinish: ((ExportSummary) -> Void)? = nil

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: ExportViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("导出")
                    .font(.headline)
                Spacer()
                Text("格式：CSV")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sourceSection(model)
                        ExportOptionsSection(model: model)
                        destinationSection(model)
                        ProgressSection(model: model)
                    }
                    .padding(18)
                }

                Divider()
                footer(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 580, height: 560)
        .task {
            if model == nil {
                model = ExportViewModel(
                    session: session,
                    source: source,
                    preferences: environment.preferences
                )
                model?.onFinish = onFinish
            }
        }
    }

    // MARK: 源

    @ViewBuilder
    private func sourceSection(_ model: ExportViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("源：")
                    .foregroundStyle(.secondary)
                Text(model.source.title)
                    .fontWeight(.medium)
            }
            Text(model.sourceDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let note = model.limitNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: 保存到

    @ViewBuilder
    private func destinationSection(_ model: ExportViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("保存到")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(model.destinationURL?.path ?? "尚未选择")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Button("选择…") { model.chooseDestination() }
                    .disabled(model.phase.isRunning)
            }
        }
    }

    // MARK: 进度

    @ViewBuilder
    private func footer(_ model: ExportViewModel) -> some View {
        HStack {
            switch model.phase {
            case .idle, .preparing, .running:
                Button("取消") {
                    if model.phase.isRunning { model.cancel() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("导出") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase.isRunning || model.destinationURL == nil)

            case .done(let summary):
                if summary.isSuccess {
                    Button("在 Finder 中显示") {
                        if let url = summary.destinationURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .disabled(summary.destinationURL == nil)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - CSV 选项

private struct ExportOptionsSection: View {

    @Bindable var model: ExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CSV 选项")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                SwiftUI.GridRow {
                    Text("分隔符")
                    Picker("", selection: $model.delimiter) {
                        ForEach(CSVExportDelimiter.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text("逗号 / 制表符 / 分号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SwiftUI.GridRow {
                    Text("换行符")
                    Picker("", selection: $model.lineEnding) {
                        ForEach(CSVLineEnding.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text("LF / CRLF")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SwiftUI.GridRow {
                    Text("文本编码")
                    Picker("", selection: $model.encoding) {
                        ForEach(CSVTextEncoding.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text("UTF-8 / UTF-8 BOM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SwiftUI.GridRow {
                    Text("NULL 表示")
                    Picker("", selection: $model.nullRepresentation) {
                        ForEach(CSVNullRepresentation.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text("空字符串 / NULL 字面量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SwiftUI.GridRow {
                    Text("日期格式")
                    Text("原样输出")
                        .frame(width: 140, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("不做时区 / 格式转换")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("包含表头", isOn: $model.includeHeader)
            Toggle("后台导出，完成后通知我", isOn: $model.backgroundExport)
                .help("打开后可以切到别的标签继续工作")
        }
    }
}

// MARK: - 进度

private struct ProgressSection: View {

    let model: ExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.phase.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在导出…")
                    Spacer()
                    Text(model.progress.displayText)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if case .done(let summary) = model.phase {
                Text(summary.message)
                    .font(.callout)
                    .foregroundStyle(summary.isSuccess ? .primary : .secondary)
            }
        }
    }
}
