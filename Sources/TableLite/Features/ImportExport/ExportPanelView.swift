import SwiftUI

// MARK: - 导出面板
//
// 见 specs/08-import-export.md §1、docs/tech-designs/11-schema-and-import-export.md §3。
// 视图只读 `ExportViewModel` 的状态、只发意图。

/// `.sheet(item:)` 的包装：`ExportViewModel.Source` 本身不是 `Identifiable`。
struct ExportSheetRequest: Identifiable {
    let id = UUID()
    var source: ExportViewModel.Source
}

struct ExportPanelView: View {

    @StateObject private var model: ExportViewModel
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss

    init(source: ExportViewModel.Source,
         session: ConnectionSession,
         fileSystem: FileSystemLocator,
         preferences: PreferencesStore) {
        _model = StateObject(wrappedValue: ExportViewModel(source: source,
                                                           session: session,
                                                           fileSystem: fileSystem,
                                                           preferences: preferences))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出")
                .font(.headline)

            sourceSection
            Divider()
            optionSection
            Divider()
            destinationSection

            if model.isExporting {
                progressSection
            }
            if let failure = model.failure {
                ExportErrorPanel(failure: failure) {
                    model.clearFailure()
                    if case .cancelled = failure { dismiss() }
                }
            }

            footer
        }
        .padding(20)
        .frame(width: 520)
        .task {
            model.attach(toasts: toasts)
            await model.prepare()
        }
        .onChange(of: model.completion) { _, completion in
            if completion != nil { dismiss() }
        }
    }

    // MARK: 源

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("源：")
                    .foregroundStyle(.secondary)
                Text(model.sourceName)
                    .font(.system(.body, design: .monospaced))
            }
            if let detail = model.sourceDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(model.rowCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let prepareError = model.prepareError {
                Text(prepareError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: CSV 选项

    private var optionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CSV 选项")
                .font(.subheadline)

            optionRow("分隔符") {
                Picker("", selection: delimiterBinding) {
                    ForEach(CSVDelimiter.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            optionRow("换行符") {
                Picker("", selection: $model.options.lineEnding) {
                    ForEach(CSVLineEnding.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            optionRow("包含表头") {
                Toggle("", isOn: $model.options.includeHeader)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
            }
            optionRow("文本编码") {
                Picker("", selection: $model.options.encoding) {
                    ForEach(CSVEncoding.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            optionRow("NULL 表示") {
                Picker("", selection: $model.options.nullStyle) {
                    ForEach(CSVNullStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            optionRow("日期格式") {
                Picker("", selection: .constant(0)) {
                    Text("原样输出").tag(0)
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(true)
            }

            Toggle("后台导出，完成后通知我", isOn: $model.runsInBackground)
                .toggleStyle(.checkbox)
                .font(.callout)

            Text("二进制内容输出为 0x… 十六进制文本；浮点与日期沿用服务器返回的原始文本。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func optionRow<Content: View>(_ title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 84, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
    }

    private var delimiterBinding: Binding<CSVDelimiter> {
        Binding(
            get: { CSVDelimiter.allCases.first { $0.character == model.options.delimiter } ?? .comma },
            set: { model.options.delimiter = $0.character }
        )
    }

    // MARK: 保存位置

    private var destinationSection: some View {
        HStack(spacing: 10) {
            Text("保存到：")
                .foregroundStyle(.secondary)
            Text(model.destinationText)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("选择…") { model.chooseDestination() }
                .disabled(model.isExporting)
        }
    }

    // MARK: 进度

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.progressText)
                .font(.callout)
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack {
            Spacer()
            if model.isExporting {
                Button("取消") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导出") {
                    model.start()
                    if model.runsInBackground { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExport)
            }
        }
    }
}

// MARK: - 导出错误面板
//
// 结构见 specs/12-feedback.md §5：一句话标题 + 原始错误（不翻译、不截断）+
// 错误码 · SQLSTATE + 数据状态说明。

private struct ExportErrorPanel: View {

    let failure: ExportViewModel.Failure
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure.title)
                .font(.subheadline)
                .foregroundStyle(.red)

            if let serverError = failure.serverError {
                Text("[错误 \(serverError.code)] SQLSTATE \(serverError.sqlState)")
                    .font(.system(size: 12, design: .monospaced))
                if !serverError.message.isEmpty {
                    Text(serverError.message)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                if let hint = serverError.chineseHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(failure.stateMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("关闭", action: onClose)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
