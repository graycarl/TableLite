import Foundation
import Security

// MARK: - 错误

/// Keychain 操作失败。`status` 是 `SecItem*` 返回的原始 `OSStatus`。
enum KeychainCredentialError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串操作失败（\(status)）：\(message)"
        }
    }
}

// MARK: - KeychainCredentialStore

/// 基于系统 Keychain 的凭据存储。见 docs/tech-designs/02-persistence.md §3。
///
/// - service：`com.graycarl.tablelite.<kind.serviceSuffix>`，区分数据库密码 / SSH 密码 / SSH Passphrase
/// - account：`connection.id.uuidString`
/// - 可访问级别：`kSecAttrAccessibleAfterFirstUnlock`（自用工具，不要求每次解锁）
/// - 写入前先 `delete` 再 `add`（Keychain 不支持直接改全部属性）
///
/// `@unchecked Sendable` 的理由：类本身无可变状态，只转发 `SecItem*`；
/// Security.framework 的这类 API 是线程安全的。
final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {

    static let servicePrefix = "com.graycarl.tablelite"

    private let servicePrefix: String

    init(servicePrefix: String = KeychainCredentialStore.servicePrefix) {
        self.servicePrefix = servicePrefix
    }

    func store(_ secret: String, for key: CredentialKey) throws {
        // 先删后加：Keychain 不能部分更新属性。
        try delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: key),
            kSecAttrAccount as String: key.connectionID.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(secret.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            storeLogger.error("Keychain 写入失败 status=\(status)")
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }

    func retrieve(_ key: CredentialKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: key),
            kSecAttrAccount as String: key.connectionID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            storeLogger.error("Keychain 读取失败 status=\(status)")
            throw KeychainCredentialError.unexpectedStatus(status)
        }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func delete(_ key: CredentialKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: key),
            kSecAttrAccount as String: key.connectionID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // 不存在视为已删除。
        guard status == errSecSuccess || status == errSecItemNotFound else {
            storeLogger.error("Keychain 删除失败 status=\(status)")
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }

    // `deleteAll(connectionID:)` 由 `CredentialStore` 的协议扩展提供，
    // 会依次删除三个 kind（见 Core/Support/Infrastructure.swift）。

    private func service(for key: CredentialKey) -> String {
        "\(servicePrefix).\(key.kind.serviceSuffix)"
    }
}
