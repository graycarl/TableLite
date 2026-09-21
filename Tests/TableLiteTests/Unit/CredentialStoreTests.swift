import XCTest
@testable import TableLite

/// 凭据存储替身的行为。真实的 Keychain 实现见 `Integration/KeychainCredentialStoreTests.swift`。
final class CredentialStoreTests: XCTestCase {

    func testSetGetHasDelete() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()

        XCTAssertNil(try store.password(for: id, kind: .mysqlPassword))
        XCTAssertFalse(try store.hasPassword(for: id, kind: .mysqlPassword))

        try store.setPassword("s3cret", for: id, kind: .mysqlPassword)
        XCTAssertEqual(try store.password(for: id, kind: .mysqlPassword), "s3cret")
        XCTAssertTrue(try store.hasPassword(for: id, kind: .mysqlPassword))

        try store.deletePassword(for: id, kind: .mysqlPassword)
        XCTAssertNil(try store.password(for: id, kind: .mysqlPassword))
    }

    func testKindsAreIndependent() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        try store.setPassword("db-pass", for: id, kind: .mysqlPassword)
        try store.setPassword("ssh-pass", for: id, kind: .sshPassword)
        try store.setPassword("key-pass", for: id, kind: .sshPassphrase)

        XCTAssertEqual(try store.password(for: id, kind: .mysqlPassword), "db-pass")
        XCTAssertEqual(try store.password(for: id, kind: .sshPassword), "ssh-pass")
        XCTAssertEqual(try store.password(for: id, kind: .sshPassphrase), "key-pass")
        XCTAssertEqual(store.count, 3)
    }

    func testDeleteAllRemovesThreeEntries() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        try store.setPassword("a", for: id, kind: .mysqlPassword)
        try store.setPassword("b", for: id, kind: .sshPassword)
        try store.setPassword("c", for: id, kind: .sshPassphrase)

        try store.deleteAll(for: id)
        XCTAssertEqual(store.count, 0)
    }

    func testDeleteAllOnlyTouchesTargetConnection() throws {
        let store = InMemoryCredentialStore()
        let first = UUID()
        let second = UUID()
        try store.setPassword("a", for: first, kind: .mysqlPassword)
        try store.setPassword("b", for: second, kind: .mysqlPassword)

        try store.deleteAll(for: first)
        XCTAssertNil(try store.password(for: first, kind: .mysqlPassword))
        XCTAssertEqual(try store.password(for: second, kind: .mysqlPassword), "b")
    }

    func testEmptyPasswordClearsEntry() throws {
        let store = InMemoryCredentialStore()
        let id = UUID()
        try store.setPassword("a", for: id, kind: .mysqlPassword)
        try store.setPassword("", for: id, kind: .mysqlPassword)
        XCTAssertNil(try store.password(for: id, kind: .mysqlPassword))
    }

    func testServiceNamesAreDistinct() {
        let names = CredentialKind.allCases.map(\.service)
        XCTAssertEqual(Set(names).count, CredentialKind.allCases.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("com.graycarl.tablelite.") })
    }
}
