import Foundation
import Observation

/// Console Log 内存缓冲 + 可选落盘。
///
/// 决策见 `02-persistence.md` §5、`specs/06-query-editor.md` §6：
/// - 记录**所有**下发到服务器的语句，带 `[data]` / `[meta]` 标签；
/// - 内存环形缓冲，容量默认 5000（偏好可调）；
/// - 默认不落盘；偏好开启后按天轮转、保留 7 天；
/// - UI 支持按标签过滤、复制全部、清空。
///
/// 并发：本类型是 `@MainActor` + `@Observable`，供 UI 直接绑定（`01-architecture.md` §3.5）。
/// 后台（`MySQLSession`）写入时用 `await store.record(...)` 回到主线程。
/// 落盘是 IO，交给 `ConsoleLogFileWriter` actor，不阻塞主线程。
@MainActor
@Observable
public final class ConsoleLogStore {

    /// 内存缓冲。UI 读取 `entries.elements` 获取快照；容量由构造参数 / `setCapacity` 控制。
    public private(set) var entries: RingBuffer<ConsoleLogEntry>

    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private var fileWriter: ConsoleLogFileWriter?
    @ObservationIgnored private var nextID: UInt64 = 1

    public init(
        capacity: Int = 5000,
        clock: Clock = SystemClock(),
        fileWriter: ConsoleLogFileWriter? = nil
    ) {
        self.entries = RingBuffer(capacity: max(1, capacity))
        self.clock = clock
        self.fileWriter = fileWriter
    }

    // MARK: - 写入

    /// 记录一条语句，id 与时间戳由本类型分配。
    ///
    /// `async` 是为了按顺序把同一条日志交给落盘 actor；不开启落盘时不会有实际挂起。
    @discardableResult
    public func record(
        tag: ConsoleLogTag,
        database: String? = nil,
        sql: String,
        durationMilliseconds: Int? = nil,
        returnedRowCount: Int? = nil,
        affectedRows: Int? = nil,
        errorCode: UInt32? = nil,
        errorMessage: String? = nil,
        isCancelled: Bool = false
    ) async -> ConsoleLogEntry {
        let entry = ConsoleLogEntry(
            id: nextID,
            timestamp: clock.now,
            tag: tag,
            database: database,
            sql: sql,
            durationMilliseconds: durationMilliseconds,
            returnedRowCount: returnedRowCount,
            affectedRows: affectedRows,
            errorCode: errorCode,
            errorMessage: errorMessage,
            isCancelled: isCancelled
        )
        await append(entry)
        return entry
    }

    /// 直接追加一条（外部已构造好的 id / 时间戳会被保留）。
    public func append(_ entry: ConsoleLogEntry) async {
        var stored = entry
        if stored.id == 0 {
            stored.id = nextID
        }
        nextID = max(nextID, stored.id) + 1
        entries.append(stored)

        if let fileWriter {
            let text = ConsoleLogFormatter.text(for: stored)
            await fileWriter.append(text)
        }
    }

    // MARK: - 读取 / 过滤

    /// 全部条目（旧的在前）。
    public var allEntries: [ConsoleLogEntry] {
        entries.elements
    }

    /// 按标签过滤。
    public func entries(tag: ConsoleLogTag) -> [ConsoleLogEntry] {
        entries.elements.filter { $0.tag == tag }
    }

    // MARK: - 容量 / 清空 / 落盘

    /// 当前是否挂了落盘 writer（偏好联动用）。
    public var hasFileWriter: Bool { fileWriter != nil }

    /// 调整容量（偏好变化时调用）；保留最近 N 条。
    public func setCapacity(_ capacity: Int) {
        let newCapacity = max(1, capacity)
        guard newCapacity != entries.capacity else { return }
        var rebuilt = RingBuffer<ConsoleLogEntry>(capacity: newCapacity)
        for element in entries.elements {
            rebuilt.append(element)
        }
        entries = rebuilt
    }

    /// 清空内存缓冲（「清空」按钮）。已落盘的文件不动。
    public func clear() {
        entries.removeAll()
    }

    /// 运行时开关「写入日志文件」（偏好改了立刻生效）。
    ///
    /// 关闭时传 `nil`；打开时由上层用 `ConsoleLogFileWriter` 构造。
    public func setFileWriter(_ writer: ConsoleLogFileWriter?) {
        fileWriter = writer
    }

    /// 落盘缓冲并关闭文件句柄（退出时调用，`05-session-management.md` §7）。
    public func flush() async {
        await fileWriter?.flush()
    }
}
