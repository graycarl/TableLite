import Foundation
import Synchronization

/// 流式 CSV 写入器：边收边写，不把整表读进内存
/// （`docs/tech-designs/11-schema-and-import-export.md` §3.1 硬约束）。
///
/// 实现要点：
/// - 写到目标文件**同目录**的临时文件，成功后原子替换，取消 / 中断时改名为 `.partial`；
/// - 内部按 256 KB 缓冲刷盘，`Snapshot.byteCount` 反映累计逻辑字节数；
/// - 状态放在 `Mutex` 里，`onEvent` 回调（在 MySQL 串行队列上执行）可安全调用。
///
/// `Mutex` 是不可复制的，所以这里是 `final class`：`onEvent` 闭包捕获的是同一个实例，
/// 不会被复制出多份状态。
public final class CSVExportSink: Sendable {

    /// 写盘统计快照。
    public struct Snapshot: Sendable, Equatable {
        public var rowCount: Int
        public var byteCount: Int
        public var flushCount: Int

        public init(rowCount: Int, byteCount: Int, flushCount: Int) {
            self.rowCount = rowCount
            self.byteCount = byteCount
            self.flushCount = flushCount
        }
    }

    private struct State {
        var handle: FileHandle?
        var options: CSVWriteOptions
        var buffer: [UInt8] = []
        var rowCount = 0
        var byteCount = 0
        var flushCount = 0
        var headerWritten = false
        var finished = false
    }

    /// 目标文件。
    public let targetURL: URL
    /// 取消 / 中断时保留的不完整文件。
    public let partialURL: URL

    private let tempURL: URL
    private let state: Mutex<State>

    /// 达到该字节数就刷一次盘。
    public static let flushThreshold = 256 * 1024

    // MARK: 初始化

    public init(targetURL: URL, options: CSVWriteOptions) throws {
        let directory = targetURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(
            ".\(targetURL.lastPathComponent).export-\(UUID().uuidString).tmp"
        )

        let fileManager = FileManager.default
        guard fileManager.createFile(
            atPath: tempURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CSVExportError.cannotCreateTempFile(tempURL.path)
        }
        guard let handle = FileHandle(forWritingAtPath: tempURL.path) else {
            throw CSVExportError.cannotOpenFile(tempURL.path)
        }

        self.targetURL = targetURL
        self.partialURL = URL(fileURLWithPath: targetURL.path + ".partial")
        self.tempURL = tempURL
        self.state = Mutex(State(handle: handle, options: options))

        if options.encoding == .utf8WithBOM {
            try appendRawBytes([0xEF, 0xBB, 0xBF])
        }
    }

    // MARK: 写入

    /// 写表头；只写一次，`includeHeader == false` 或 header 为 nil 时不写。
    public func writeHeaderIfNeeded(_ header: [String]?) throws {
        try state.withLock { state in
            guard !state.headerWritten else { return }
            state.headerWritten = true
            guard state.options.includeHeader, let header else { return }
            let line = header
                .map { CSVCodec.encodeField(.text($0), options: state.options) }
                .joined(separator: CSVCodec.delimiterString(state.options.delimiter))
            try Self.writeLine(line, state: &state)
        }
    }

    /// 追加一行。
    public func append(_ fields: [CSVField]) throws {
        try state.withLock { state in
            guard !state.finished else { return }
            let line = fields
                .map { CSVCodec.encodeField($0, options: state.options) }
                .joined(separator: CSVCodec.delimiterString(state.options.delimiter))
            try Self.writeLine(line, state: &state)
            state.rowCount += 1
        }
    }

    public func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(rowCount: state.rowCount, byteCount: state.byteCount, flushCount: state.flushCount)
        }
    }

    // MARK: 收尾

    /// 成功收尾：刷盘 → 关闭 → 原子替换目标文件。
    public func finish() throws {
        let temp = tempURL
        let target = targetURL
        try state.withLock { state in
            guard !state.finished else { return }
            state.finished = true
            try Self.flush(state: &state)
            try state.handle?.close()
            state.handle = nil

            let fileManager = FileManager.default
            do {
                if fileManager.fileExists(atPath: target.path) {
                    _ = try fileManager.replaceItemAt(target, withItemAt: temp)
                } else {
                    try fileManager.moveItem(at: temp, to: target)
                }
            } catch {
                throw CSVExportError.replaceFailed(String(describing: error))
            }
        }
    }

    /// 取消 / 中断收尾：刷盘 → 关闭 → 保留为 `.partial`。
    public func abort() {
        let temp = tempURL
        let partial = partialURL
        state.withLock { state in
            guard !state.finished else { return }
            state.finished = true
            try? Self.flush(state: &state)
            try? state.handle?.close()
            state.handle = nil

            let fileManager = FileManager.default
            try? fileManager.removeItem(at: partial)
            if fileManager.fileExists(atPath: temp.path) {
                try? fileManager.moveItem(at: temp, to: partial)
            }
        }
    }

    // MARK: 内部

    private func appendRawBytes(_ bytes: [UInt8]) throws {
        try state.withLock { state in
            state.buffer.append(contentsOf: bytes)
            state.byteCount += bytes.count
            if state.buffer.count >= Self.flushThreshold {
                try Self.flush(state: &state)
            }
        }
    }

    private static func writeLine(_ line: String, state: inout State) throws {
        let body = Array(line.utf8)
        state.buffer.append(contentsOf: body)
        state.buffer.append(contentsOf: state.options.lineEnding.bytes)
        state.byteCount += body.count + state.options.lineEnding.bytes.count
        if state.buffer.count >= flushThreshold {
            try flush(state: &state)
        }
    }

    private static func flush(state: inout State) throws {
        guard !state.buffer.isEmpty else { return }
        guard let handle = state.handle else { return }
        do {
            try handle.write(contentsOf: Data(state.buffer))
        } catch {
            throw CSVExportError.writeFailed(String(describing: error))
        }
        state.buffer.removeAll(keepingCapacity: true)
        state.flushCount += 1
    }
}
