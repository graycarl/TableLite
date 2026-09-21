import Foundation
import Security
import Synchronization

// MARK: - 种类

/// 凭据种类。`service` 前缀区分用途，`account` 固定为 `connection.id`。
///
/// 见 `02-persistence.md` §3。
public enum CredentialKind: String, Sendable, CaseIterable {

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

    /// Keychain 的 `kSecAttrService`。
    public var service: String {
        switch self {
        case .mysqlPassword: return "com.graycarl.tablelite.mysql-password"
        case .sshPassword: return "com.graycarl.tablelite.ssh-password"
        case .sshPassphrase: return "com.graycarl.tablelite.ssh-passphrase"
        }
    }
}

// MARK: - 协议

/// 凭据存储的注入点（`15-testing.md` §3）。
///
/// 真实实现走 Security.framework；单测与 CI 用 `InMemoryCredentialStore`。
public protocol CredentialStore: Sendable {

    /// 读取凭据；不存在返回 `nil`。
    func password(for connectionID: UUID, kind: CredentialKind) throws -> String?

    /// 写入（先删再加，Keychain 不支持直接改全部属性）。空串表示清除。
    func setPassword(_ password: String, for connectionID: UUID, kind: CredentialKind) throws

    /// 删除单条；不存在时静默返回（幂等）。
    func deletePassword(for connectionID: UUID, kind: CredentialKind) throws

    /// 删除该连接的全部凭据（`02-persistence.md` §3：删除连接必须连带删除三个条目）。
    func deleteAll(for connectionID: UUID) throws

    /// 是否存在。
    func hasPassword(for connectionID: UUID, kind: CredentialKind) throws -> Bool
}

// MARK: - Keychain 实现

/// 基于 Security.framework 的真实实现。
///
/// - `kSecAttrAccessibleAfterFirstUnlock`：自用工具，不要求每次解锁（`02-persistence.md` §3）。
/// - 写入是先 `delete` 再 `add`。
public struct KeychainCredentialStore: CredentialStore {

    public init() {}

    public func password(for connectionID: UUID, kind: CredentialKind) throws -> String? {
        var query = Self.baseQuery(connectionID: connectionID, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            StoreLog.error("读取钥匙串失败（\(kind.rawValue)，\(connectionID.uuidString)）：OSStatus \(status)")
            throw CredentialStoreError.keychain(status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            StoreLog.warning("钥匙串内容不是 UTF-8（\(kind.rawValue)，\(connectionID.uuidString)）")
            throw CredentialStoreError.malformedValue(kind)
        }
        return text
    }

    public func setPassword(_ password: String, for connectionID: UUID, kind: CredentialKind) throws {
        guard !password.isEmpty else {
            try deletePassword(for: connectionID, kind: kind)
            return
        }
        // 先删再加：Keychain 不能部分更新属性。
        try deletePassword(for: connectionID, kind: kind)

        var attributes = Self.baseQuery(connectionID: connectionID, kind: kind)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            StoreLog.error("写入钥匙串失败（\(kind.rawValue)，\(connectionID.uuidString)）：OSStatus \(status)")
            throw CredentialStoreError.keychain(status)
        }
    }

    public func deletePassword(for connectionID: UUID, kind: CredentialKind) throws {
        let status = SecItemDelete(Self.baseQuery(connectionID: connectionID, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            StoreLog.error("删除钥匙串条目失败（\(kind.rawValue)，\(connectionID.uuidString)）：OSStatus \(status)")
            throw CredentialStoreError.keychain(status)
        }
    }

    public func deleteAll(for connectionID: UUID) throws {
        var firstError: CredentialStoreError?
        for kind in CredentialKind.allCases {
            do {
                try deletePassword(for: connectionID, kind: kind)
            } catch let error as CredentialStoreError {
                if firstError == nil { firstError = error }
            } catch {
                StoreLog.error("删除钥匙串条目失败（\(kind.rawValue)，\(connectionID.uuidString)）：\(error)")
            }
        }
        if let firstError { throw firstError }
    }

    public func hasPassword(for connectionID: UUID, kind: CredentialKind) throws -> Bool {
        try password(for: connectionID, kind: kind) != nil
    }

    // MARK: 查询构造

    private static func baseQuery(connectionID: UUID, kind: CredentialKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.service,
            kSecAttrAccount as String: connectionID.uuidString.lowercased(),
        ]
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
        storage.withLock { $0[Self.key(connectionID, kind)] != nil }
    }

    /// 测试辅助：当前存了多少条。
    public var count: Int {
        storage.withLock { $0.count }
    }

    private static func key(_ connectionID: UUID, _ kind: CredentialKind) -> String {
        "\(kind.rawValue)|\(connectionID.uuidString.lowercased())"
    }
}
