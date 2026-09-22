import Foundation

/// 标签现场（`session.json`）的读写。
///
/// 决策见 `05-session-management.md` §8：
/// - 存 `session.json`，按连接记标签现场；**启动只读不套用**（S36）；
/// - 写文件用「临时文件 + 原子替换」（`02-persistence.md` §2.1）。
///
/// 并发：actor，文件 IO 不占主线程。
public actor SessionStateStore {

    private let layout: AppStorageLayout
    private var notices: [String] = []

    public init(layout: AppStorageLayout) {
        self.layout = layout
    }

    /// 读取恢复状态；文件不存在返回 `nil`。
    ///
    /// 遇到不认识的版本或损坏内容：备份成 `session.json.bak-<版本>`，返回 `nil`（不恢复），
    /// 并记一条说明（`02-persistence.md` §9）。
    public func load() throws -> SessionStateFile? {
        guard let data = try AtomicFileWriter.read(layout.sessionFile) else { return nil }

        do {
            let file = try JSONDecoder().decode(SessionStateFile.self, from: data)
            guard file.schemaVersion <= SessionStateFile.currentSchemaVersion else {
                try backupSessionFile(version: file.schemaVersion)
                return nil
            }
            return file
        } catch {
            StoreLog.error("解析 session.json 失败：\(error)")
            try backupSessionFile(version: Self.detectVersion(in: data))
            return nil
        }
    }

    /// 原子写入恢复状态。
    public func save(_ state: SessionStateFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            StoreLog.error("编码 session.json 失败：\(error)")
            throw ConnectionStoreError.encodingFailed
        }
        try AtomicFileWriter.write(data, to: layout.sessionFile)
    }

    /// 删除 `session.json`（主动清空）。
    public func clear() throws {
        try AtomicFileWriter.remove(layout.sessionFile)
    }

    /// `session.json` 引用到的全部草稿 id（供孤儿清理使用）。
    public func referencedDraftIDs() throws -> Set<UUID> {
        guard let state = try load() else { return [] }
        return Self.referencedDraftIDs(in: state)
    }

    /// 取走待提示的说明。
    public func takeNotices() -> [String] {
        let result = notices
        notices.removeAll()
        return result
    }

    /// 从状态里收集草稿 id。
    public static func referencedDraftIDs(in state: SessionStateFile) -> Set<UUID> {
        var ids: Set<UUID> = []
        for session in state.sessions {
            for tab in session.tabs {
                if let draftID = tab.queryDraftID { ids.insert(draftID) }
            }
        }
        return ids
    }

    // MARK: - 内部

    private static func detectVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["schemaVersion"] as? Int
    }

    private func backupSessionFile(version: Int?) throws {
        let suffix = version.map(String.init) ?? "unknown"
        do {
            let backup = try AtomicFileWriter.backup(layout.sessionFile, suffix: suffix)
            let notice = "连接恢复文件版本 \(version.map(String.init) ?? "未知") 无法识别，已备份为 \(backup.lastPathComponent)。"
            StoreLog.warning(notice)
            notices.append(notice)
        } catch {
            StoreLog.error("备份 session.json 失败：\(error)")
        }
    }
}
