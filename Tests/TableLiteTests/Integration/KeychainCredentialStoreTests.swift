import XCTest
@testable import TableLite

/// 真实的 `Security.framework` 实现。
///
/// 钥匙串在单测 / CI 环境里可能不可用（无签名、无 GUI、可能弹窗），因此**默认跳过**。
/// 本地验证方式：
///
///     TABLELITE_KEYCHAIN_TESTS=1 make test
///
/// 或者手动跑一次 App 的连接表单（写入 / 回填 / 清除密码）。
final class KeychainCredentialStoreTests: XCTestCase {

    private func requireKeychain() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TABLELITE_KEYCHAIN_TESTS"] == "1",
            "设置 TABLELITE_KEYCHAIN_TESTS=1 才会跑真实钥匙串测试"
        )
    }

    func testSetGetOverwriteDelete() throws {
        try requireKeychain()
        let store = KeychainCredentialStore()
        let id = UUID()
        defer { try? store.deleteAll(for: id) }

        try store.setPassword("s3cret", for: id, kind: .mysqlPassword)
        XCTAssertEqual(try store.password(for: id, kind: .mysqlPassword), "s3cret")

        // 写入前先删再加，覆盖应生效
        try store.setPassword("updated", for: id, kind: .mysqlPassword)
        XCTAssertEqual(try store.password(for: id, kind: .mysqlPassword), "updated")

        try store.deletePassword(for: id, kind: .mysqlPassword)
        XCTAssertNil(try store.password(for: id, kind: .mysqlPassword))
    }

    func testKindsAndDeleteAll() throws {
        try requireKeychain()
        let store = KeychainCredentialStore()
        let id = UUID()
        defer { try? store.deleteAll(for: id) }

        try store.setPassword("db", for: id, kind: .mysqlPassword)
        try store.setPassword("ssh", for: id, kind: .sshPassword)
        try store.setPassword("key", for: id, kind: .sshPassphrase)

        XCTAssertEqual(try store.password(for: id, kind: .sshPassword), "ssh")
        XCTAssertTrue(try store.hasPassword(for: id, kind: .sshPassphrase))

        try store.deleteAll(for: id)
        XCTAssertFalse(try store.hasPassword(for: id, kind: .mysqlPassword))
        XCTAssertFalse(try store.hasPassword(for: id, kind: .sshPassword))
        XCTAssertFalse(try store.hasPassword(for: id, kind: .sshPassphrase))
    }
}
