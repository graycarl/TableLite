import Foundation

// MARK: - 错误

enum SessionStateStoreError: Error, LocalizedError, Equatable {
    case unsupportedVersion(backedUpTo: URL)
    case malformedFile

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let url):
            return "会话恢复文件版本不受支持，已备份到 \(url.lastPathComponent)，并使用默认状态重建。"
        case .malformedFile:
            return "会话恢复文件损坏，无法解析。"
        }
    }
}

// MARK: - SessionStateStore

/// 会话恢复状态 `session.json`。见 docs/tech-designs/05-session-management.md §8、
/// docs/tech-designs/02-persistence.md §7 §9。
///
/// - 恢复后不自动连接（由调用方决定）。
/// - 可在偏好中关闭；关闭时不调用 `save`。
/// - 临时文件 + 原子替换，文件 0600。
@MainActor
final class SessionStateStore {

    static let schemaVersion = 1

    private let fileSystem: FileSystemLocator
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(fileSystem: FileSystemLocator) {
        self.fileSystem = fileSystem
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    var fileURL: URL {
        fileSystem.applicationSupportDirectory.appendingPathComponent("session.json")
    }

    // MARK: 模型

    struct State: Codable, Hashable, Sendable {
        var schemaVersion: Int
        var activeConnectionID: UUID?
        var sessions: [SessionSnapshot]
    }

    struct SessionSnapshot: Codable, Hashable, Sendable {
        var connectionID: UUID
        var selectedDatabase: String?
        var activeTabIndex: Int?
        var tabs: [TabSnapshot]
    }

    struct TabSnapshot: Codable, Hashable, Sendable {
        /// tableData / tableStructure / objectDefinition / query
        var kind: String
        var database: String?
        var objectName: String?
        var draftID: UUID?
        var pageIndex: Int?
        var pageSize: Int?
        var sort: [SortDescriptor]?
        var filter: FilterSet?
        var hiddenColumns: [String]?
        var columnWidths: [String: Double]?
    }

    // MARK: 读写

    /// 文件不存在时返回 nil。
    func load() throws -> State? {
        let url = fileURL
        guard fileSystem.fileExists(at: url) else { return nil }
        let data = try fileSystem.readData(at: url)
        guard !data.isEmpty else { return nil }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SessionStateStoreError.malformedFile
        }
        guard let dict = root as? [String: Any] else {
            throw SessionStateStoreError.malformedFile
        }

        let version = (dict["schemaVersion"] as? Int) ?? Self.schemaVersion
        guard version == Self.schemaVersion else {
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("session.json.bak-\(version)")
            try fileSystem.moveItem(at: url, to: backupURL)
            try save(State(schemaVersion: Self.schemaVersion, activeConnectionID: nil, sessions: []))
            storeLogger.warning("session.json 版本 \(version) 不受支持，已备份并重建")
            throw SessionStateStoreError.unsupportedVersion(backedUpTo: backupURL)
        }

        let templateData = try encoder.encode(State(schemaVersion: Self.schemaVersion, activeConnectionID: nil, sessions: []))
        let template = try JSONSerialization.jsonObject(with: templateData)
        let merged = Self.merge(defaults: template, overrides: dict)
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try decoder.decode(State.self, from: mergedData)
    }

    func save(_ state: State) throws {
        let data = try encoder.encode(state)
        try fileSystem.writeAtomically(data, to: fileURL, permissions: 0o600)
    }

    func clear() throws {
        try fileSystem.removeItemIfExists(at: fileURL)
    }

    // MARK: 私有

    /// 缺失字段取默认值：用默认 `State` 做模板，把存储对象叠上去。
    /// 未知字段会被解码器忽略。见 docs/tech-designs/02-persistence.md §9。
    private static func merge(defaults base: Any, overrides: Any) -> Any {
        guard let baseDict = base as? [String: Any], let overrideDict = overrides as? [String: Any] else {
            return overrides
        }
        var result = baseDict
        for (key, value) in overrideDict {
            if let existing = baseDict[key] {
                result[key] = merge(defaults: existing, overrides: value)
            } else {
                result[key] = value
            }
        }
        return result
    }
}
