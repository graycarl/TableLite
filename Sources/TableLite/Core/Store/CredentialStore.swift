import Foundation
import Synchronization

// MARK: - 种类

/// 凭据种类。`rawValue` 就是 `credentials.json` 里的字段名（`02-persistence.md` §3）。
public enum CredentialKind: String, Sendable, CaseIterable, Codable {

    /// 数据库密码。
    case mysqlPassword
    /// SSH 账号密码。
    case sshPassword
    /// SSH 私钥 Passphrase。
    case sshPassphrase

    /// 界面 / 日志里的中文名。
    public var displayName: String {
        switch self {
        case .mysqlPassword: return "数据库密码"
        case .sshPassword: return "SSH 密码"
        case .sshPassphrase: return "SSH 私钥口令"
        }
    }
}

// MARK: - 协议

/// 凭据存储的注入点（`15-testing.md` §3）。
///
/// 真实实现是 `FileCredentialStore`（本机 JSON 文件）；单测与 CI 用 `InMemoryCredentialStore`。
public protocol CredentialStore: Sendable {

    /// 读取凭据；不存在返回 `nil`。
    func password(for connectionID: UUID, kind: CredentialKind) throws -> String?

    /// 写入；空串表示清除。
    func setPassword(_ password: String, for connectionID: UUID, kind: CredentialKind) throws

    /// 删除单条；不存在时静默返回（幂等）。
    func deletePassword(for connectionID: UUID, kind: CredentialKind) throws

    /// 删除该连接的全部凭据（`02-persistence.md` §3：删除连接必须连带删除三条）。
    func deleteAll(for connectionID: UUID) throws

    /// 是否存在。
    func hasPassword(for connectionID: UUID, kind: CredentialKind) throws -> Bool
}

// MARK: - 文件格式（纯逻辑）

/// `credentials.json` 的内存表示。
///
/// 纯数据 + 纯变换，不碰文件系统，方便单测（`15-testing.md` §2）。
/// 读写与权限由 `FileCredentialStore` 负责。
public struct CredentialFile: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 1

    /// 落盘格式版本（`02-persistence.md` §9）。
    public var schemaVersion: Int
    /// key 是 `connection.id` 的小写形式；value 是 `CredentialKind.rawValue` → 明文口令。
    public var entries: [String: [String: String]]

    public init(
        schemaVersion: Int = CredentialFile.currentSchemaVersion,
        entries: [String: [String: String]] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    /// 向前兼容读取：缺 `schemaVersion` 取当前值，缺 `entries` 取空；未知字段忽略。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? CredentialFile.currentSchemaVersion
        entries = try container.decodeIfPresent([String: [String: String]].self, forKey: .entries) ?? [:]
    }

    // MARK: 查询与变换

    /// 文件里的连接键。
    public static func key(for connectionID: UUID) -> String {
        connectionID.uuidString.lowercased()
    }

    public func password(for connectionID: UUID, kind: CredentialKind) -> String? {
        entries[Self.key(for: connectionID)]?[kind.rawValue]
    }

    public func hasPassword(for connectionID: UUID, kind: CredentialKind) -> Bool {
        password(for: connectionID, kind: kind) != nil
    }

    /// 空串等价于「没有」：写空串就是删除。
    public mutating func setPassword(_ password: String, for connectionID: UUID, kind: CredentialKind) {
        guard !password.isEmpty else {
            deletePassword(for: connectionID, kind: kind)
            return
        }
        entries[Self.key(for: connectionID), default: [:]][kind.rawValue] = password
    }

    public mutating func deletePassword(for connectionID: UUID, kind: CredentialKind) {
        let key = Self.key(for: connectionID)
        guard var secrets = entries[key] else { return }
        secrets.removeValue(forKey: kind.rawValue)
        if secrets.isEmpty {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = secrets
        }
    }

    public mutating func deleteAll(for connectionID: UUID) {
        entries.removeValue(forKey: Self.key(for: connectionID))
    }

    // MARK: 编解码

    public static func decode(from data: Data) throws -> CredentialFile {
        try JSONDecoder().decode(CredentialFile.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - 文件实现

/// 基于单个 JSON 文件的凭据存储。
///
/// 决策与安全边界见 `02-persistence.md` §3：文件 `credentials.json`、`0600`、**明文**、
/// 写入走「临时文件 + 原子替换」；旧 Keychain 条目不读不写、不迁移
/// （`13-open-questions.md` L45、S42）。
public struct FileCredentialStore: CredentialStore {

    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    public init(layout: AppStorageLayout) {
        self.file = layout.credentialsFile
    }

    // MARK: 协议实现

    public func password(for connectionID: UUID, kind: CredentialKind) throws -> String? {
        try load().password(for: connectionID, kind: kind)
    }

    public func setPassword(_ password: String, for connectionID: UUID, kind: CredentialKind) throws {
        var file = try load()
        file.setPassword(password, for: connectionID, kind: kind)
        try save(file)
    }

    public func deletePassword(for connectionID: UUID, kind: CredentialKind) throws {
        var file = try load()
        file.deletePassword(for: connectionID, kind: kind)
        try save(file)
    }

    public func deleteAll(for connectionID: UUID) throws {
        var file = try load()
        file.deleteAll(for: connectionID)
        try save(file)
    }

    public func hasPassword(for connectionID: UUID, kind: CredentialKind) throws -> Bool {
        try load().hasPassword(for: connectionID, kind: kind)
    }

    // MARK: 读写

    /// 读取；文件不存在时返回空表。
    ///
    /// 遇到不认识的版本或解析失败：备份成 `credentials.json.bak-<版本|unknown>` 后重建空表
    /// （`02-persistence.md` §9），代价是那台机器要重新输一次密码。
    private func load() throws -> CredentialFile {
        guard let data = try AtomicFileWriter.read(file) else { return CredentialFile() }

        do {
            let decoded = try CredentialFile.decode(from: data)
            guard decoded.schemaVersion <= CredentialFile.currentSchemaVersion else {
                StoreLog.error("凭据文件版本 \(decoded.schemaVersion) 无法识别，已备份并重建。")
                return try rebuild(suffix: "\(decoded.schemaVersion)")
            }
            return decoded
        } catch {
            StoreLog.error("解析凭据文件失败：\(error)")
            return try rebuild(suffix: "unknown")
        }
    }

    private func rebuild(suffix: String) throws -> CredentialFile {
        _ = try? AtomicFileWriter.backup(file, suffix: suffix)
        let empty = CredentialFile()
        try AtomicFileWriter.write(try empty.encoded(), to: file)
        return empty
    }

    private func save(_ credentials: CredentialFile) throws {
        try AtomicFileWriter.write(try credentials.encoded(), to: file)
    }
}

// MARK: - 内存实现

/// 单测 / 预览用。`Mutex` 保证 `Sendable`，不引入 `@unchecked Sendable`。
public final class InMemoryCredentialStore: CredentialStore {

    private let storage = Mutex<[String: String]>([:])

    public init() {}

    public func password(for connectionID: UUID, kind: CredentialKind) throws -> String? {
        storage.withLock { $0[Self.key(connectionID, kind)] }
    }

    public func setPassword(_ password: String, for connectionID: UUID, kind: CredentialKind) throws {
        if password.isEmpty {
            try deletePassword(for: connectionID, kind: kind)
            return
        }
        storage.withLock { $0[Self.key(connectionID, kind)] = password }
    }

    public func deletePassword(for connectionID: UUID, kind: CredentialKind) throws {
        _ = storage.withLock { $0.removeValue(forKey: Self.key(connectionID, kind)) }
    }

    public func deleteAll(for connectionID: UUID) throws {
        storage.withLock { dictionary in
            for kind in CredentialKind.allCases {
                dictionary.removeValue(forKey: Self.key(connectionID, kind))
            }
        }
    }

    public func hasPassword(for connectionID: UUID, kind: CredentialKind) throws -> Bool {
        try password(for: connectionID, kind: kind) != nil
    }

    /// 测试辅助：当前存了多少条。
    public var count: Int {
        storage.withLock { $0.count }
    }

    private static func key(_ connectionID: UUID, _ kind: CredentialKind) -> String {
        "\(kind.rawValue)|\(connectionID.uuidString.lowercased())"
    }
}
