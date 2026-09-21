import Foundation

// MARK: - DraftStore

/// 查询标签草稿：每个标签一个文件 `drafts/<uuid>.sql`。
/// 见 docs/tech-designs/05-session-management.md §9。
@MainActor
final class DraftStore {

    private let fileSystem: FileSystemLocator
    private let clock: Clock

    init(fileSystem: FileSystemLocator, clock: Clock) {
        self.fileSystem = fileSystem
        self.clock = clock
    }

    var draftsDirectory: URL {
        fileSystem.applicationSupportDirectory.appendingPathComponent("drafts", isDirectory: true)
    }

    func url(for draftID: UUID) -> URL {
        draftsDirectory.appendingPathComponent("\(draftID.uuidString).sql")
    }

    /// 防抖由调用方负责（1s），这里只做落盘。
    func save(_ sql: String, draftID: UUID) throws {
        try fileSystem.writeAtomically(Data(sql.utf8), to: url(for: draftID), permissions: 0o600)
    }

    func load(draftID: UUID) throws -> String? {
        let url = url(for: draftID)
        guard fileSystem.fileExists(at: url) else { return nil }
        let data = try fileSystem.readData(at: url)
        return String(decoding: data, as: UTF8.self)
    }

    func delete(draftID: UUID) throws {
        try fileSystem.removeItemIfExists(at: url(for: draftID))
    }

    /// 启动时清理孤儿草稿：不在 `referenced` 中且修改时间早于 `days` 天。
    /// 见 docs/tech-designs/05-session-management.md §9（默认 30 天）。
    func removeOrphans(referenced: Set<UUID>, olderThan days: Int = 30) throws {
        let directory = draftsDirectory
        guard fileSystem.fileExists(at: directory) else { return }
        let cutoff = clock.now.addingTimeInterval(-Double(days) * 24 * 60 * 60)

        for url in try fileSystem.contentsOfDirectory(at: directory) {
            guard url.pathExtension == "sql" else { continue }
            guard let draftID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                // 文件名不是草稿 id：也按孤儿处理，但只删过期的，避免误删正在写入的临时文件。
                if let modified = fileSystem.modificationDate(at: url), modified < cutoff {
                    try fileSystem.removeItemIfExists(at: url)
                }
                continue
            }
            if referenced.contains(draftID) { continue }
            if let modified = fileSystem.modificationDate(at: url), modified >= cutoff { continue }
            try fileSystem.removeItemIfExists(at: url)
        }
    }
}
