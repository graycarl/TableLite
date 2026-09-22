import SwiftUI

/// CSV 导入向导（三步）。入口契约：
/// ```swift
/// .sheet(item: $importRequest) { request in
///     ImportWizardView(
///         session: session,
///         defaultDatabase: request.database,
///         defaultTable: request.table
///     ) { summary in ... }
/// }
/// ```
///
/// 面板自管尺寸与关闭（`@Environment(\.dismiss)`），完成后通过 `onFinish` 回调。
/// 需求见 `specs/08-import-export.md` §2；只读拦截见 `specs/09-readonly-mode.md` §4。
struct ImportWizardView: View {

    let session: ConnectionSession
    let defaultDatabase: String?
    let defaultTable: String?
    var onFinish: ((ImportSummary) -> Void)? = nil

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: ImportViewModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let model {
                Group {
                    switch model.step {
                    case .pickFile:
                        ImportStepPickerView(model: model)
                    case .mapping:
                        ImportStepMappingView(model: model)
                    case .executing:
                        ImportStepExecuteView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 640)
        .task {
            if model == nil {
                let created = ImportViewModel(
                    session: session,
                    defaultDatabase: defaultDatabase,
                    defaultTable: defaultTable
                )
                created.onFinish = onFinish
                model = created
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Spacer()
            if session.isReadOnly {
                Label("该连接处于只读模式，无法导入数据", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var title: String {
        guard let model else { return "导入 CSV" }
        switch model.step {
        case .pickFile: return "导入 CSV（1/3）"
        case .mapping: return "导入 CSV（2/3）"
        case .executing: return "导入 CSV（3/3）"
        }
    }

    @ViewBuilder
    private func footer(_ model: ImportViewModel) -> some View {
        HStack {
            switch model.step {
            case .pickFile:
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("下一步") {
                    Task { await model.goToMapping() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canProceedFromPicker() || session.isReadOnly)

            case .mapping:
                Button("上一步") { model.goBackToFilePicker() }
                Spacer()
                Text("预计导入：\(model.plannedRowCount) 行")
                    .foregroundStyle(.secondary)
                Button("开始导入") { model.startImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canProceedToExecute)

            case .executing:
                if model.phase.isRunning {
                    Button("取消") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - 第一步：选文件与解析选项

private struct ImportStepPickerView: View {

    @Bindable var model: ImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("文件")
                    .foregroundStyle(.secondary)
                Text(model.fileURL?.path ?? "尚未选择")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Button("选择…") { model.chooseFile() }
                    .disabled(model.isReadOnly)
            }

            if model.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在解析…").foregroundStyle(.secondary)
                }
            }

            if let error = model.parseError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Text("预览（前 \(model.previewRowLimit) 行）")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ImportPreviewTable(header: model.previewHeader, records: model.previewRecords)

            if let hint = model.parseHint {
                Text(hint)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 24) {
                Picker("分隔符", selection: $model.delimiterOption) {
                    ForEach(ImportViewModel.DelimiterOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .frame(width: 220)

                Toggle("首行是表头", isOn: $model.hasHeader)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 24) {
                Picker("文本编码", selection: $model.encodingOption) {
                    ForEach(CSVInputEncoding.allCases, id: \.self) { encoding in
                        Text(encoding.displayName).tag(encoding)
                    }
                }
                .frame(width: 260)

                Picker("换行符", selection: $model.lineEndingOption) {
                    ForEach(ImportLineEndingOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .frame(width: 240)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .onChange(of: model.delimiterOption) { _, _ in model.reparse() }
        .onChange(of: model.hasHeader) { _, _ in model.reparse() }
        .onChange(of: model.encodingOption) { _, _ in model.reparse() }
    }
}

/// 预览表格。
private struct ImportPreviewTable: View {

    let header: [String]
    let records: [CSVRecord]

    private let columnWidth: CGFloat = 150

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, name in
                        Text(name.isEmpty ? " " : name)
                            .font(.caption.bold())
                            .lineLimit(1)
                            .frame(width: columnWidth, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                }
                .background(Color.secondary.opacity(0.12))

                ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                    HStack(spacing: 0) {
                        ForEach(Array(record.fields.enumerated()), id: \.offset) { _, field in
                            Text(field.isEmpty ? " " : field)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: columnWidth, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                }
            }
        }
        .frame(minHeight: 150, maxHeight: 220)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }
}

// MARK: - 第二步：列映射 / 新表类型

private struct ImportStepMappingView: View {

    @Bindable var model: ImportViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                targetSection
                if model.isNewTableTarget {
                    newTableSection
                } else {
                    mappingSection
                }
                optionsSection
                if !model.requiredColumnWarnings.isEmpty {
                    let names = model.requiredColumnWarnings.map(\.name).joined(separator: ", ")
                    Label("目标列不可为空但没有映射：\(names)", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(18)
        }
        .onChange(of: model.isNewTableTarget) { _, _ in
            Task { await model.prepareMapping() }
        }
    }

    private var targetSection: some View {
        HStack(spacing: 12) {
            Text("目标")
                .foregroundStyle(.secondary)
            if model.defaultExistingTable != nil {
                Picker("", selection: $model.isNewTableTarget) {
                    Text("导入到已有表").tag(false)
                    Text("导入到新表").tag(true)
                }
                .labelsHidden()
                .frame(width: 220)
            } else {
                Text("导入到新表")
                    .fontWeight(.medium)
            }
            Text(model.isNewTableTarget ? model.newTableName : "\(model.target.database).\(model.target.tableName)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var newTableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("新表名")
                TextField("表名", text: $model.newTableName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Button("全部按文本类型创建") { model.applyTextForAllColumns() }
            }

            mappingTable(showsType: true)

            if let sql = model.previewCreateTableSQL {
                Text("将要执行：")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(sql)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("目标表：\(model.target.database).\(model.target.tableName)")
                .font(.callout)
            mappingTable(showsType: false)
        }
    }

    private func mappingTable(showsType: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("CSV 列").frame(width: 160, alignment: .leading)
                Text("→").frame(width: 30)
                if showsType {
                    Text("推断类型").frame(width: 220, alignment: .leading)
                    Text("推断依据").frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("目标列").frame(width: 220, alignment: .leading)
                    Text("类型").frame(width: 150, alignment: .leading)
                    Text("说明").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)

            Divider()

            ForEach($model.mappings) { $mapping in
                HStack(spacing: 0) {
                    Text(mapping.csvName)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: 160, alignment: .leading)
                    Text("→")
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                    if showsType {
                        Picker("", selection: $mapping.deducedType) {
                            ForEach(CSVColumnType.allCases, id: \.self) { type in
                                Text(type.sqlText).tag(type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        Text(mapping.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("", selection: $mapping.targetColumn) {
                            Text("（跳过）").tag(String?.none)
                            ForEach(model.targetColumns, id: \.id) { column in
                                Text(ImportMappingDisplay.optionText(for: column))
                                    .tag(String?.some(column.name))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        Text(ImportMappingDisplay.typeText(for: mapping, targetColumns: model.targetColumns))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 150, alignment: .leading)
                        Text(ImportMappingDisplay.noteText(for: mapping, targetColumns: model.targetColumns))
                            .font(.caption)
                            .foregroundStyle(mapping.isSkipped ? .orange : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 3)
                Divider()
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("遇到错误时继续导入其余行", isOn: $model.options.continueOnError)
                .toggleStyle(.checkbox)
            Toggle("导入前先清空目标表（TRUNCATE）", isOn: $model.options.truncateFirst)
                .toggleStyle(.checkbox)
                .disabled(model.isReadOnly)
            Toggle("在事务中导入", isOn: $model.options.useTransaction)
                .toggleStyle(.checkbox)
            HStack(spacing: 8) {
                Text("每批行数")
                    .foregroundStyle(.secondary)
                Stepper(
                    "\(model.options.batchSize)",
                    value: $model.options.batchSize,
                    in: 1...5_000,
                    step: 100
                )
                .frame(width: 160)
            }
            if model.options.useTransaction {
                Text("勾选事务后，遇到错误会整体回滚（此时代码里的「继续导入」不生效）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 第三步：执行

private struct ImportStepExecuteView: View {

    @Bindable var model: ImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.phase.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在导入…")
                        Spacer()
                        Text(model.progressText)
                            .foregroundStyle(.secondary)
                    }
                    if let percent = model.progressPercentText {
                        // 进度条 + 百分比（`manual/08` 图 8-5）。
                        HStack(spacing: 8) {
                            ProgressView(value: model.progressFraction)
                                .progressViewStyle(.linear)
                            Text(percent)
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack(spacing: 16) {
                Text("成功 \(model.rowsWritten)")
                    .foregroundStyle(.green)
                Text("失败 \(model.failureCount)")
                    .foregroundStyle(model.failureCount > 0 ? .red : .secondary)
            }

            if case .done(let summary) = model.phase {
                Text(summary.message)
                    .font(.callout)
            }

            if model.failureCount > 0 {
                Text("失败原因（前 100 条）：")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.failures.prefix(100).enumerated()), id: \.offset) { _, failure in
                            Text("第 \(failure.lineNumber) 行 → \(failure.message)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("导出失败行 CSV") { exportFailures() }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private func exportFailures() {
        guard let url = ImportExportFilePanels.chooseExportDestination(
            suggestedName: "\(model.target.tableName)-errors.csv"
        ) else { return }
        let csv = model.failureReportCSV()
        try? AtomicFileWriter.write(csv, to: url)
    }
}
