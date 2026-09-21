import Combine
import Foundation
import os

// MARK: - 共享日志
//
// 所有 Store 用同一个 Logger。见 docs/tech-designs/02-persistence.md §8。
// `Logger` 是 Sendable，模块级 `let` 在 Swift 6 严格并发下安全。
let storeLogger = Logger(subsystem: "com.graycarl.tablelite", category: "store")

// MARK: - 错误

/// 连接配置持久化错误。`unsupportedVersion` 会被 UI 直接展示。
/// 见 docs/tech-designs/02-persistence.md §9。
enum ConnectionStoreError: Error, LocalizedError, Equatable {
    /// 未知的 `schemaVersion`：已把原文件备份到 `backedUpTo`，并按默认值重建。
    case unsupportedVersion(backedUpTo: URL)
    /// 文件存在但不是合法 JSON 对象。
    case malformedFile
    /// `add` 时 id 已存在。
    case duplicateID(UUID)
    /// `update` 时找不到 id。
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let url):
            return "连接配置版本不受支持，已备份到 \(url.lastPathComponent)，并使用默认配置重建。"
        case .malformedFile:
            return "连接配置文件损坏，无法解析。"
        case .duplicateID:
            return "连接已存在，无法重复添加。"
        case .notFound:
            return "找不到对应的连接。"
        }
    }
}

// MARK: - ConnectionStore

/// `connections.json` 读写。见 docs/tech-designs/02-persistence.md §2。
///
/// - 路径：`applicationSupportDirectory/connections.json`
/// - 文件 0600、目录 0700，临时文件 + 原子替换
/// - JSON 里**禁止**出现 `password` / `passphrase`；读到就丢弃并记 warning
@MainActor
final class ConnectionStore: ObservableObject {

    static let schemaVersion = 1

    @Published private(set) var connections: [Connection] = []

    let fileSystem: FileSystemLocator
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(fileSystem: FileSystemLocator) {
        self.fileSystem = fileSystem
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    var fileURL: URL {
        fileSystem.applicationSupportDirectory.appendingPathComponent("connections.json")
    }

    // MARK: 读写

    /// 读取配置。文件不存在时得到空列表（不抛错）。
    func load() throws {
        let url = fileURL
        guard fileSystem.fileExists(at: url) else {
            connections = []
            return
        }
        let data = try fileSystem.readData(at: url)
        guard !data.isEmpty else {
            connections = []
            return
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConnectionStoreError.malformedFile
        }
        guard let dict = root as? [String: Any] else {
            throw ConnectionStoreError.malformedFile
        }

        // 敏感字段只应存在于 Keychain，这里只做丢弃 + 告警，不抛错。
        if Self.containsSensitiveKey(dict) {
            storeLogger.warning("connections.json 含 password/passphrase 字段，已丢弃（见 docs/tech-designs/02-persistence.md §2）")
        }

        let version = (dict["schemaVersion"] as? Int) ?? Self.schemaVersion
        guard version == Self.schemaVersion else {
            // 未知版本：备份原文件 → 按默认值重建 → 抛出可展示的错误。
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("connections.json.bak-\(version)")
            try fileSystem.moveItem(at: url, to: backupURL)
            connections = []
            try save()
            storeLogger.warning("connections.json 版本 \(version) 不受支持，已备份并重建")
            throw ConnectionStoreError.unsupportedVersion(backedUpTo: backupURL)
        }

        let rawConnections = (dict["connections"] as? [Any]) ?? []
        connections = try rawConnections.map { try decodeConnection(from: $0) }
    }

    /// 原子写入。父目录会被创建为 0700，文件为 0600。
    func save() throws {
        let envelope = Envelope(schemaVersion: Self.schemaVersion, connections: connections)
        let data = try encoder.encode(envelope)
        try fileSystem.writeAtomically(data, to: fileURL, permissions: 0o600)
    }

    // MARK: 增删改查

    func add(_ connection: Connection) throws {
        guard !connections.contains(where: { $0.id == connection.id }) else {
            throw ConnectionStoreError.duplicateID(connection.id)
        }
        connections.append(connection)
        try save()
    }

    func update(_ connection: Connection) throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else {
            throw ConnectionStoreError.notFound(connection.id)
        }
        connections[index] = connection
        try save()
    }

    func remove(id: UUID) throws {
        connections.removeAll { $0.id == id }
        try save()
    }

    func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    // MARK: 私有

    private struct Envelope: Codable {
        var schemaVersion: Int
        var connections: [Connection]
    }

    /// 用 `Connection()` 的默认值做模板，把存储对象叠上去再解码：
    /// 缺失字段取默认值、未知字段被 `Connection` 的解码器忽略。
    /// 见 docs/tech-designs/02-persistence.md §9。
    private func decodeConnection(from raw: Any) throws -> Connection {
        let templateData = try encoder.encode(Connection())
        let template = try JSONSerialization.jsonObject(with: templateData)
        let merged = Self.merge(defaults: template, overrides: raw)
        let data = try JSONSerialization.data(withJSONObject: merged)
        return try decoder.decode(Connection.self, from: data)
    }

    private static func merge(defaults base: Any, overrides: Any) -> Any {
        guard let baseDict = base as? [String: Any], let overrideDict = overrides as? [String: Any] else {
            return overrides
        }
        var result = baseDict
        for (key, value) in overrideDict {
            if let existing = baseDict[key] {
                result[key] = merge(defaults: existing, overrides: value)
            } else {
                // 未知字段照单保留，解码时被忽略。
                result[key] = value
            }
        }
        return result
    }

    private static func containsSensitiveKey(_ object: Any) -> Bool {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if key == "password" || key == "passphrase" { return true }
                if containsSensitiveKey(value) { return true }
            }
        } else if let array = object as? [Any] {
            for item in array where containsSensitiveKey(item) { return true }
        }
        return false
    }
}
