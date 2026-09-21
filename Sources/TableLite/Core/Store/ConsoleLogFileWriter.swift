import Foundation

/// Console Log 落盘器。
///
/// 决策见 `02-persistence.md` §5：偏好开启「写入日志文件」时落盘，**按天轮转、保留 7 天**。
/// `05-session-management.md` §7：退出时调用 `flush()`。
///
/// 只在 actor 内访问文件句柄，避免跨隔离域。
public actor ConsoleLogFileWriter {

    /// 默认保留天数。
    public static let defaultRetentionDays = 7

    private let directory: URL
    private let retentionDays: Int
    private let clock: Clock
    private let calendar: Calendar

    private var openDay: String?
    private var handle: FileHandle?

    public init(
        directory: URL,
        retentionDays: Int = ConsoleLogFileWriter.defaultRetentionDays,
        clock: Clock = SystemClock(),
        calendar: Calendar = .current
    ) {
        self.directory = directory
        self.retentionDays = max(1, retentionDays)
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - 写入

    /// 追加一段文本（调用方已经带换行）。
    public func append(_ text: String) {
        let day = ConsoleLogFormatter.dayString(clock.now, calendar: calendar)
        guard let handle = ensureHandle(for: day) else { return }
        do {
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            StoreLog.error("写入 Console Log 失败：\(error)")
            closeHandle()
        }
    }

    /// 同步并关闭当前文件。退出时调用（`05-session-management.md` §7）。
    public func flush() {
        guard let handle else { return }
        do {
            try handle.synchronize()
        } catch {
            StoreLog.warning("同步 Console Log 失败：\(error)")
        }
        closeHandle()
    }

    // MARK: - 轮转与清理

    private func ensureHandle(for day: String) -> FileHandle? {
        if openDay == day, let handle { return handle }
        closeHandle()

        do {
            try AtomicFileWriter.ensureDirectory(directory)
            let url = directory.appendingPathComponent(ConsoleLogFormatter.fileName(day: day))
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: AtomicFileWriter.filePermissions]
                )
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.handle = handle
            self.openDay = day
            pruneOldFiles()
            return handle
        } catch {
            StoreLog.error("打开 Console Log 文件失败：\(error)")
            return nil
        }
    }

    private func closeHandle() {
        if let handle { try? handle.close() }
        handle = nil
        openDay = nil
    }

    /// 删除超过保留天数的日志文件。
    public func pruneOldFiles() {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: clock.now) else { return }
        let cutoffDay = ConsoleLogFormatter.dayString(cutoff, calendar: calendar)
        for file in AtomicFileWriter.contents(of: directory) {
            guard let day = ConsoleLogFormatter.day(fromFileName: file.lastPathComponent) else { continue }
            guard day < cutoffDay else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                StoreLog.info("清理过期 Console Log：\(file.lastPathComponent)")
            } catch {
                StoreLog.error("删除过期 Console Log 失败 \(file.path)：\(error)")
            }
        }
    }
}
