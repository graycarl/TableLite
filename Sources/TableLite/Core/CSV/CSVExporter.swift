import Foundation

// MARK: - CSV 导出（流式）
//
// 硬约束（docs/tech-designs/11-schema-and-import-export.md §3.1）：
// **绝不把全部数据读进内存**——边收边写；写临时文件，成功后原子替换目标；
// 取消 / 中断时把临时文件改名为 `.partial` 并抛 incomplete，已写内容保留。
enum CSVExportError: Error, Hashable, Sendable {
    case incomplete(partialURL: URL)
    case destinationNotWritable(String)
}

/// 流式 CSV 导出器。
///
/// `@unchecked Sendable` 理由：两个存储属性 `fileSystem` / `options` 都是不可变且 `Sendable` 的；
/// `write` 的所有可变状态（临时文件句柄、缓冲区、计数）都是每次调用内部的局部变量，
/// 不跨调用共享。因此并发调用之间除了不可变配置外没有共享可变状态。
/// 这里不用锁是因为 `write` 是 async、会跨挂起点，用 `NSLock` 持有锁跨 `await` 是错误做法。
final class CSVExporter: @unchecked Sendable {

    private let fileSystem: FileSystemLocator
    private let options: CSVCodec.Options

    init(fileSystem: FileSystemLocator, options: CSVCodec.Options) {
        self.fileSystem = fileSystem
        self.options = options
    }

    /// 流式写入目标文件。
    ///
    /// - `rows`：逐行值；调用方负责用 unbuffered 查询喂入。
    /// - `binaryColumnFlags`：与投影列一一对应的「是否二进制家族」，用于把二进制列
    ///   （即使字节恰好是合法 UTF-8）稳定输出为 `0x…` hex（docs/11 §2.1）。
    ///   缺省 / 长度不足的位置按非二进制处理。
    /// - `onProgress(已写入行数, 已写入字节数)`。
    /// - `cancellation`：定期轮询；返回 true 则转 `.partial` 并抛 `incomplete`。
    func write(to destination: URL,
               header: [String],
               rows: AsyncThrowingStream<[CellValue], Error>,
               onProgress: @Sendable (Int, Int) -> Void,
               cancellation: @Sendable () -> Bool,
               binaryColumnFlags: [Bool] = []) async throws {

        // 目标可写性（文件本身或所在目录）
        let parent = destination.deletingLastPathComponent()
        do {
            try fileSystem.ensureDirectory(at: parent)
        } catch {
            throw CSVExportError.destinationNotWritable("无法创建导出目录：\(parent.path)")
        }
        guard isWritableDestination(destination) else {
            throw CSVExportError.destinationNotWritable("目标文件不可写：\(destination.path)")
        }
        try fileSystem.ensureDirectory(at: fileSystem.temporaryDirectory)

        let tempURL = fileSystem.temporaryDirectory
            .appendingPathComponent("tablelite-export-\(UUID().uuidString).csv")

        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw CSVExportError.destinationNotWritable("无法创建临时文件")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: tempURL)
        } catch {
            try? fileSystem.removeItemIfExists(at: tempURL)
            throw CSVExportError.destinationNotWritable("无法打开临时文件：\(error.localizedDescription)")
        }

        let lineEnding = Array(options.lineEnding.text.utf8)
        let flushThreshold = 64 * 1024
        var writtenRows = 0
        var writtenBytes = 0
        var buffer = Data()

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            writtenBytes += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }

        func writeLine(_ line: String) throws {
            buffer.append(contentsOf: Array(line.utf8))
            buffer.append(contentsOf: lineEnding)
            if buffer.count >= flushThreshold { try flush() }
        }

        func closeHandle() {
            try? handle.close()
        }

        func moveToPartial() throws -> URL {
            let partial = destination.appendingPathExtension("partial")
            try? fileSystem.removeItemIfExists(at: partial)
            try fileSystem.moveItem(at: tempURL, to: partial)
            return partial
        }

        do {
            let bom = CSVCodec.byteOrderMark(for: options.encoding)
            if !bom.isEmpty { buffer.append(contentsOf: bom) }
            if options.includeHeader, !header.isEmpty {
                try writeLine(CSVCodec.encodeRow(header, delimiter: options.delimiter))
            }
            onProgress(0, 0)

            for try await values in rows {
                if cancellation() || Task.isCancelled {
                    try flush()
                    closeHandle()
                    throw CSVExportError.incomplete(partialURL: try moveToPartial())
                }
                let fields = values.enumerated().map { index, value in
                    let isBinary = index < binaryColumnFlags.count ? binaryColumnFlags[index] : false
                    return CSVCodec.exportText(value, isBinary: isBinary, nullStyle: options.nullStyle)
                }
                try writeLine(CSVCodec.encodeRow(fields, delimiter: options.delimiter))
                writtenRows += 1
                if writtenRows % 1000 == 0 { onProgress(writtenRows, writtenBytes) }
            }

            try flush()
            closeHandle()
            // 目标存在 → FileManager 的原子替换；否则直接移动。
            try replace(destination: destination, with: tempURL)
            onProgress(writtenRows, writtenBytes)
        } catch let error as CSVExportError {
            closeHandle()
            throw error
        } catch {
            // 读取中断（连接断开 / 写盘失败等）：保留已写内容为 `.partial`
            closeHandle()
            let partial = (try? moveToPartial()) ?? destination.appendingPathExtension("partial")
            throw CSVExportError.incomplete(partialURL: partial)
        }
    }

    // MARK: 内部

    private func isWritableDestination(_ destination: URL) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            return manager.isWritableFile(atPath: destination.path)
        }
        return manager.isWritableFile(atPath: destination.deletingLastPathComponent().path)
    }

    /// 成功路径：把临时文件原子替换到目标。
    ///
    /// `FileSystemLocator.moveItem` 是「先删后移」，不是原子的；这里对已存在的目标
    /// 用 `FileManager.replaceItemAt` 保证真正的原子替换（读到的永远是完整文件），
    /// 目标不存在时直接移动。
    private func replace(destination: URL, with tempURL: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
                return
            } catch {
                // 回退到 locator 的移动
            }
        }
        do {
            try fileSystem.moveItem(at: tempURL, to: destination)
        } catch {
            throw CSVExportError.destinationNotWritable("无法写入目标文件：\(destination.path)")
        }
    }
}
