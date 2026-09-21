import Combine
import Foundation

// MARK: - ConsoleLogStore

/// SQL Console Log：内存环形缓冲 + 可选落盘。
/// 见 docs/tech-designs/02-persistence.md §5、specs/06-query-editor.md §6。
///
/// - 记录所有下发到服务器的语句，带 `[data]`（用户发起）/ `[meta]`（客户端自动发出）标签。
/// - 容量默认 5000，超出丢最旧。
/// - 默认不落盘；开启后按天轮转、保留 7 天，日志目录 `applicationSupportDirectory/logs`。
@MainActor
final class ConsoleLogStore: ObservableObject {

    enum Category: String, Sendable {
        case data
        case meta
    }

    struct Entry: Hashable, Sendable, Identifiable {
        /// 由 store 的 `append` 统一分配。
        var id: UInt64 = 0
        var timestamp: Date
        var category: Category
        var database: String? = nil
        var sql: String
        var elapsed: Duration = .zero
        var rowCount: Int? = nil
        var affectedRows: Int? = nil
        var errorCode: UInt32? = nil
        var errorMessage: String? = nil
    }

    static let defaultCapacity = 5000
    static let retentionDays = 7

    /// 新的在尾部。
    @Published private(set) var entries: [Entry] = []

    let capacity: Int

    private let clock: Clock
    private let fileSystem: FileSystemLocator?
    private let writeToFile: Bool
    private var nextID: UInt64 = 1
    /// 已产生但尚未落盘的行；`writeToFile == false` 时恒为空。
    private var pendingLines: [String] = []

    private let timestampFormatter: DateFormatter
    private let dayFormatter: DateFormatter

    init(capacity: Int = ConsoleLogStore.defaultCapacity,
         clock: Clock = LiveClock(),
         fileSystem: FileSystemLocator? = nil,
         writeToFile: Bool = false) {
        self.capacity = max(1, capacity)
        self.clock = clock
        self.fileSystem = fileSystem
        self.writeToFile = writeToFile

        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.timestampFormatter = timestampFormatter

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = dayFormatter
    }

    // MARK: 写入 / 清理

    /// 追加一条。`id` 由 store 统一分配，传入值被忽略。
    func append(_ entry: Entry) {
        var stored = entry
        stored.id = nextID
        nextID &+= 1

        entries.append(stored)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        if writeToFile {
            pendingLines.append(line(for: stored))
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// 复制全部用。
    var textDump: String {
        entries.map { line(for: $0) }.joined(separator: "\n")
    }

    // MARK: 落盘

    var logsDirectory: URL? {
        fileSystem?.applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// 把待落盘内容写入当天文件，并清理超过 7 天的旧文件。
    func flushToDisk() throws {
        guard writeToFile, let fileSystem, let logsDirectory else { return }
        try fileSystem.ensureDirectory(at: logsDirectory)

        if !pendingLines.isEmpty {
            let name = "console-\(dayFormatter.string(from: clock.now)).log"
            let url = logsDirectory.appendingPathComponent(name)
            var chunk = pendingLines.joined(separator: "\n")
            chunk += "\n"
            if fileSystem.fileExists(at: url) {
                var existing = try fileSystem.readData(at: url)
                existing.append(Data(chunk.utf8))
                try fileSystem.writeAtomically(existing, to: url, permissions: 0o600)
            } else {
                try fileSystem.writeAtomically(Data(chunk.utf8), to: url, permissions: 0o600)
            }
            pendingLines.removeAll()
        }

        try pruneOldLogs(in: logsDirectory)
    }

    private func pruneOldLogs(in directory: URL) throws {
        guard let fileSystem else { return }
        let cutoff = clock.now.addingTimeInterval(-Double(Self.retentionDays) * 24 * 60 * 60)
        for url in try fileSystem.contentsOfDirectory(at: directory) {
            guard url.pathExtension == "log" else { continue }
            if let modified = fileSystem.modificationDate(at: url), modified < cutoff {
                try fileSystem.removeItemIfExists(at: url)
            }
        }
    }

    // MARK: 单行格式化

    /// 形如：`[2026-01-01 12:00:00] [data] (db) 12.5ms SELECT 1`
    private func line(for entry: Entry) -> String {
        var text = "[\(timestampFormatter.string(from: entry.timestamp))] [\(entry.category.rawValue)] "
        if let database = entry.database, !database.isEmpty {
            text += "(\(database)) "
        }
        text += "\(Self.elapsedText(entry.elapsed)) "
        text += entry.sql.replacingOccurrences(of: "\n", with: " ")
        if let errorCode = entry.errorCode {
            text += " → 错误 \(errorCode)"
            if let message = entry.errorMessage, !message.isEmpty {
                text += "：\(message.replacingOccurrences(of: "\n", with: " "))"
            }
        } else if let affectedRows = entry.affectedRows {
            text += " → 影响 \(affectedRows) 行"
        } else if let rowCount = entry.rowCount {
            text += " → \(rowCount) 行"
        }
        return text
    }

    private static func elapsedText(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return String(format: "%.1fms", milliseconds)
    }
}
