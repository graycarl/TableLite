import Foundation

/// 查询标签草稿存储。
///
/// 决策见 `05-session-management.md` §9：
/// - 每个查询标签一个 `draftId`，编辑内容防抖 1s 落盘（防抖由上层做，这里只提供读写删）；
/// - 标签关闭时删除对应草稿（已另存为磁盘文件的除外，由上层判断）；
/// - 启动时清理超过 30 天且未被 `session.json` 引用的孤儿草稿。
///
/// 并发：actor，文件 IO 不占主线程。
public actor QueryDraftStore {

    /// 孤儿草稿的判定天数（`05-session-management.md` §9）。
    public static let orphanAgeDays = 30

    private let layout: AppStorageLayout
    private let clock: Clock
    private let retentionDays: Int

    public init(
        layout: AppStorageLayout,
        clock: Clock = SystemClock(),
        retentionDays: Int = QueryDraftStore.orphanAgeDays
    ) {
        self.layout = layout
        self.clock = clock
        self.retentionDays = max(1, retentionDays)
    }

    // MARK: - 读写

    /// 读取草稿内容；不存在返回 `nil`。
    public func read(id: UUID) throws -> String? {
        try AtomicFileWriter.readText(layout.draftFile(id: id))
    }

    /// 写入草稿（原子替换）。
    public func write(_ text: String, id: UUID) throws {
        try AtomicFileWriter.write(text, to: layout.draftFile(id: id))
    }

    /// 删除草稿；不存在时静默返回。
    public func delete(id: UUID) throws {
        try AtomicFileWriter.remove(layout.draftFile(id: id))
    }

    /// 列出全部草稿 id。
    public func allDraftIDs() throws -> [UUID] {
        try AtomicFileWriter.ensureDirectory(layout.draftsDirectory)
        return AtomicFileWriter.contents(of: layout.draftsDirectory).compactMap {
            AppStorageLayout.draftID(fromFileName: $0.lastPathComponent)
        }
    }

    // MARK: - 孤儿清理

    /// 删除「超过保留天数且未被引用」的草稿，返回被删掉的 id。
    @discardableResult
    public func cleanupOrphans(referencedIDs: Set<UUID>) throws -> [UUID] {
        try AtomicFileWriter.ensureDirectory(layout.draftsDirectory)
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: clock.now) else {
            return []
        }

        var removed: [UUID] = []
        for file in AtomicFileWriter.contents(of: layout.draftsDirectory) {
            guard let draftID = AppStorageLayout.draftID(fromFileName: file.lastPathComponent) else { continue }
            guard !referencedIDs.contains(draftID) else { continue }
            guard let modified = AtomicFileWriter.modificationDate(file), modified < cutoff else { continue }
            do {
                try AtomicFileWriter.remove(file)
                removed.append(draftID)
                StoreLog.info("清理孤儿草稿：\(file.lastPathComponent)")
            } catch {
                StoreLog.error("删除孤儿草稿失败 \(file.path)：\(error)")
            }
        }
        return removed
    }

    /// 便捷入口：从 `session.json` 内容收集引用后清理。
    @discardableResult
    public func cleanupOrphans(referencedFrom state: SessionStateFile?) throws -> [UUID] {
        let referenced = state.map { SessionStateStore.referencedDraftIDs(in: $0) } ?? []
        return try cleanupOrphans(referencedIDs: referenced)
    }

    /// 清空全部草稿。
    public func removeAll() throws {
        for id in try allDraftIDs() {
            try delete(id: id)
        }
    }
}
