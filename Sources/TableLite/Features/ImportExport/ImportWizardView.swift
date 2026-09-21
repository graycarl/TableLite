import AppKit
import SwiftUI

// MARK: - 导入向导
//
// 三步：选文件与解析选项 → 列映射 → 执行。见 specs/08-import-export.md §2。
// 视图只读 `ImportViewModel` 的状态、只发意图。

/// `.sheet(item:)` 的包装：携带「从哪个表右键进入」的初始目标。
struct ImportSheetRequest: Identifiable {
    let id = UUID()
    var ref: TableRef?
}

struct ImportWizardView: View {

    @StateObject private var model: ImportViewModel
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss

    private let initialRef: TableRef?

    init(initialRef: TableRef?,
         session: ConnectionSession,
         preferences: PreferencesStore,
         fileSystem: FileSystemLocator) {
        self.initialRef = initialRef
        _model = StateObject(wrappedValue: ImportViewModel(session: session,
                                                           preferences: preferences,
                                                           fileSystem: fileSystem))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.step.title)
                .font(.headline)

            Group {
                switch model.step {
                case .selectFile: stepOne
                case .mapping: stepTwo
                case .execute: stepThree
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 720)
        .frame(minHeight: 480)
        .task {
            if let initialRef {
                model.targetRef = initialRef
            }
        }
        .onChange(of: model.step) { _, step in
            if step == .execute {
                model.startImport()
            }
        }
        .onChange(of: model.targetMode) { _, _ in
            Task { await model.prepareMappingStep() }
        }
        .onChange(of: model.hasHeader) { _, _ in
            model.rebuildMappingsFromCurrentSource()
        }
        .onChange(of: model.delimiter) { _, _ in
            model.reparseWithChosenDelimiter()
        }
        .onChange(of: model.finished) { _, finished in
            guard finished else { return }
            announce()
            if model.successCount > 0 {
                Task { await model.refreshTargetTable() }
            }
        }
    }

    // MARK: - 第一步

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("文件：")
                    .foregroundStyle(.secondary)
                Text(model.fileURL?.path ?? "尚未选择文件")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("选择…") { model.chooseFile() }
            }

            previewTable

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("分隔符").foregroundStyle(.secondary)
                    Picker("", selection: $model.delimiter) {
                        ForEach(CSVDelimiter.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                HStack(spacing: 6) {
                    Text("文本编码").foregroundStyle(.secondary)
                    Text(model.detectedEncodingName.map { "自动检测：\($0)" } ?? "自动检测")
                        .font(.callout)
                }
                Toggle("首行是表头", isOn: $model.hasHeader)
                    .toggleStyle(.checkbox)
            }

            if model.needsManualEncoding {
                HStack(spacing: 6) {
                    Text("手动选择编码").foregroundStyle(.secondary)
                    Picker("", selection: $model.manualEncoding) {
                        ForEach(ImportViewModel.ManualEncoding.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Button("重新解析") { model.reparseWithManualEncoding() }
                }
            }

            if let hint = model.delimiterHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = model.parseErrorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var previewTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("预览（前 20 行）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.previewRows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .frame(minWidth: 90, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                            }
                            Spacer(minLength: 0)
                        }
                        .background(index == 0 && model.hasHeader
                                    ? Color.secondary.opacity(0.12)
                                    : Color.clear)
                    }
                }
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    // MARK: - 第二步

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Picker("", selection: $model.targetMode) {
                    ForEach(ImportViewModel.TargetMode.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)

                if model.targetMode == .existingTable {
                    Picker("", selection: targetRefBinding) {
                        Text("选择目标表").tag(TableRef?.none)
                        ForEach(model.targetTables) { object in
                            Text(object.name).tag(TableRef?.some(TableRef(database: model.database,
                                                                          table: object.name)))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                } else {
                    Text("表名").foregroundStyle(.secondary)
                    TextField("新表名", text: $model.newTableName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Toggle("全部按文本类型创建", isOn: $model.fallbackAllText)
                        .toggleStyle(.checkbox)
                }
                if model.isLoadingTarget {
                    ProgressView().controlSize(.small)
                }
            }

            if model.targetMode == .existingTable {
                mappingTable
            } else {
                newTableEditor
            }

            HStack(spacing: 18) {
                Toggle("遇到错误时继续导入其余行", isOn: $model.continueOnError)
                    .toggleStyle(.checkbox)
                Toggle("导入前先清空目标表（TRUNCATE）", isOn: $model.truncateBeforeImport)
                    .toggleStyle(.checkbox)
                Toggle("在事务中导入", isOn: $model.useTransaction)
                    .toggleStyle(.checkbox)
            }

            if !model.unmappedRequiredColumns.isEmpty {
                Text("以下非空列没有映射：\(model.unmappedRequiredColumns.joined(separator: "、"))。"
                    + "导入可能因这些列为空而失败。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Text("预计导入：\(TableDataViewModelLogic.groupedDigits(model.estimatedRowCount)) 行")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var targetRefBinding: Binding<TableRef?> {
        Binding(
            get: { model.targetRef },
            set: { newValue in
                guard let newValue else { return }
                Task { await model.selectTargetTable(newValue) }
            }
        )
    }

    private var mappingTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CSV 列").frame(width: 150, alignment: .leading)
                Text("→").frame(width: 20)
                Text("目标列").frame(width: 240, alignment: .leading)
                Text("说明").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.mappings) { row in
                        HStack {
                            Text(row.sourceName)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            Text("→").frame(width: 20)
                            Picker("", selection: mappingBinding(row)) {
                                Text("(跳过)").tag(String?.none)
                                ForEach(model.selectableTargetColumns, id: \.name) { column in
                                    Text(column.name).tag(String?.some(column.name))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                            Text(description(for: row))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(height: 180)
        }
    }

    private func mappingBinding(_ row: ImportViewModel.MappingRow) -> Binding<String?> {
        Binding(
            get: { row.targetColumn },
            set: { model.setMapping(sourceIndex: row.id, targetColumn: $0) }
        )
    }

    private func description(for row: ImportViewModel.MappingRow) -> String {
        guard let name = row.targetColumn,
              let column = model.selectableTargetColumns.first(where: { $0.name == name }) else {
            return "跳过"
        }
        var parts = [column.rawTypeText]
        if column.isPrimaryKey { parts.append("主键") }
        if !column.isNullable { parts.append("非空") }
        return parts.joined(separator: " · ")
    }

    private var newTableEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.newColumns.enumerated()), id: \.element.id) { index, column in
                        HStack(spacing: 10) {
                            TextField("列名", text: Binding(
                                get: { column.name },
                                set: { model.setNewColumnName(index: index, name: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)

                            Picker("", selection: Binding(
                                get: { column.type },
                                set: { model.setNewColumnType(index: index, type: $0) }
                            )) {
                                ForEach(ImportViewModel.newColumnTypes, id: \.self) { type in
                                    Text(type).tag(type)
                                }
                                if !ImportViewModel.newColumnTypes.contains(column.type) {
                                    Text(column.type).tag(column.type)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(height: 140)

            Text("将执行的建表语句")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.createTableSQL)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    // MARK: - 第三步

    private var stepThree: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isImporting ? "正在导入…" : "导入结束")
                .font(.subheadline)

            ProgressView(value: model.progressFraction)
                .progressViewStyle(.linear)
            Text(model.progressText)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                Text("成功 \(TableDataViewModelLogic.groupedDigits(model.successCount))")
                    .foregroundStyle(.green)
                Text("失败 \(TableDataViewModelLogic.groupedDigits(model.failureCount))")
                    .foregroundStyle(model.failureCount > 0 ? .red : .secondary)
            }

            if let notice = model.cancellationNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if !model.failures.isEmpty {
                failureList
            }
        }
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("失败原因（前 100 条）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("导出失败行…") { model.exportFailures() }
                    .buttonStyle(.link)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.failures.enumerated()), id: \.offset) { _, failure in
                        Text(lineNumber: failure.rowNumber, message: failure.message)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
    }

    // MARK: - 底部按钮

    private var footer: some View {
        HStack {
            Spacer()
            switch model.step {
            case .selectFile:
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下一步") { Task { await model.advance() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance)

            case .mapping:
                Button("上一步") { model.goBack() }
                Button("下一步") { Task { await model.advance() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance)

            case .execute:
                if model.isImporting {
                    Button("取消") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // MARK: 完成通知

    private func announce() {
        guard model.finished else { return }
        let text = "导入完成：成功 \(TableDataViewModelLogic.groupedDigits(model.successCount)) 行，"
            + "失败 \(TableDataViewModelLogic.groupedDigits(model.failureCount)) 行"
        toasts.show(text)
    }
}

private extension Text {
    init(lineNumber: Int, message: String) {
        self.init("第 \(lineNumber) 行：\(message)")
    }
}
