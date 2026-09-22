import Foundation

/// 连接元数据仓库。
///
/// 持久化格式与决策见 `02-persistence.md` §2、§9：
/// - 存 `connections.json`，带 `schemaVersion`；
/// - **禁止**把密码 / passphrase 写进 JSON，读取时若发现直接丢弃并告警；
/// - 写入用「临时文件 + 原子替换」，文件 `0600`；
/// - 只做向前兼容读取：未知字段忽略、缺失字段取默认值；遇到不认识的版本备份后重建。
///
/// 删除连接时连带清理 Keychain 里的三条凭据（`02-persistence.md` §3）。
public actor ConnectionStore {

    /// 一次加载的结果：连接列表 + 需要提示给用户的说明（例如丢弃了密码字段）。
    public struct LoadResult: Sendable, Equatable {
        public var connections: [Connection]
        public var notices: [String]

        public init(connections: [Connection], notices: [String] = []) {
            self.connections = connections
            self.notices = notices
        }
    }

    private let layout: AppStorageLayout
    private let credentials: CredentialStore

    /// 内存缓存；`nil` 表示还没读过文件。
    private var cache: [Connection]?
    private var notices: [String] = []

    public init(layout: AppStorageLayout, credentials: CredentialStore) {
        self.layout = layout
        self.credentials = credentials
    }

    // MARK: - 读取

    /// 加载连接列表。首次调用读文件，之后走缓存。
    ///
    /// `notices` 会一直保留到 `takeNotices()` 被调用，避免被中间调用
    /// （例如连接表单的 `upsert`）顺带消费掉导致用户看不到。
    public func load() throws -> LoadResult {
        if let cache {
            return LoadResult(connections: cache, notices: notices)
        }

        guard let data = try AtomicFileWriter.read(layout.connectionsFile) else {
            cache = []
            return LoadResult(connections: [])
        }

        do {
            let decoded = try ConnectionMetadataFile.decode(from: data)
            if !decoded.droppedSecretKeys.isEmpty {
                let keys = decoded.droppedSecretKeys.joined(separator: "、")
                StoreLog.warning("connections.json 中发现明文密码字段（\(keys)），已丢弃。")
                notices.append("连接文件里发现了不该保存的密码字段（\(keys)），已自动丢弃。")
            }

            guard decoded.file.schemaVersion <= ConnectionMetadataFile.currentSchemaVersion else {
                return try rebuild(from: data, version: decoded.file.schemaVersion)
            }

            cache = decoded.file.connections
            return LoadResult(connections: cache ?? [], notices: notices)
        } catch {
            StoreLog.error("解析 connections.json 失败：\(error)")
            return try rebuild(from: data, version: Self.detectVersion(in: data))
        }
    }

    /// 当前所有连接的快照。
    public func allConnections() throws -> [Connection] {
        try load().connections
    }

    /// 按 id 取一个连接。
    public func connection(id: UUID) throws -> Connection? {
        try load().connections.first { $0.id == id }
    }

    /// 取走待提示的说明（不在 `load()` 里消费时使用）。
    public func takeNotices() -> [String] {
        let result = notices
        notices.removeAll()
        return result
    }

    // MARK: - 写入

    /// 整体覆盖保存。
    public func save(_ connections: [Connection]) throws {
        let file = ConnectionMetadataFile(connections: connections)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(file)
        } catch {
            StoreLog.error("编码连接元数据失败：\(error)")
            throw ConnectionStoreError.encodingFailed
        }
        try AtomicFileWriter.write(data, to: layout.connectionsFile)
        cache = connections
    }

    /// 新增或按 id 覆盖一个连接，返回保存后的列表。
    @discardableResult
    public func upsert(_ connection: Connection) throws -> [Connection] {
        var list = try load().connections
        if let index = list.firstIndex(where: { $0.id == connection.id }) {
            list[index] = connection
        } else {
            list.append(connection)
        }
        try save(list)
        return list
    }

    /// 删除连接：先清 Keychain 凭据，成功后再写 JSON。
    ///
    /// 顺序是刻意的：钥匙串清理失败时**不**删 JSON，避免留下无人认领的密码；
    /// 用户可以重试删除。
    public func delete(id: UUID) throws {
        var list = try load().connections
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let connection = list[index]

        do {
            try credentials.deleteAll(for: id)
        } catch {
            StoreLog.error("删除连接「\(connection.name)」的钥匙串凭据失败：\(error)")
            throw ConnectionStoreError.credentialCleanupFailed(id)
        }

        list.remove(at: index)
        try save(list)
    }

    /// 丢弃缓存，下次 `load()` 重新读文件（例如检测到外部修改后）。
    public func invalidateCache() {
        cache = nil
    }

    // MARK: - 版本与损坏处理

    /// 从 JSON 原文取 `schemaVersion`；取不到返回 `nil`。
    private static func detectVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["schemaVersion"] as? Int
    }

    /// `02-persistence.md` §9：不认识的版本 → 备份成 `<文件名>.bak-<版本>`，按默认值重建。
    private func rebuild(from data: Data, version: Int?) throws -> LoadResult {
        let suffix = version.map(String.init) ?? "unknown"
        let backupName: String
        do {
            backupName = try AtomicFileWriter.backup(layout.connectionsFile, suffix: suffix).lastPathComponent
        } catch {
            StoreLog.error("备份 connections.json 失败：\(error)")
            backupName = "connections.json.bak-\(suffix)"
        }

        let notice = "连接文件版本 \(version.map(String.init) ?? "未知") 无法识别，已备份为 \(backupName)，并按默认值重建。"
        StoreLog.warning(notice)
        notices.append(notice)
        cache = []
        return LoadResult(connections: [], notices: notices)
    }
}
