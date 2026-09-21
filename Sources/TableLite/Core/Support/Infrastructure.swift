import Foundation

// MARK: - Clock
//
// 业务代码禁止直接调用 `Date()`；空闲回收、TTL、防抖、超时都通过 Clock。
// 见 docs/tech-designs/15-testing.md §3。

protocol Clock: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

extension Clock {
    func sleep(for duration: Duration) async throws {
        try await sleep(seconds: TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18)
    }
}

struct LiveClock: Clock {
    var now: Date { Date() }

    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// 测试用：时间由调用方推进。
final class InMemoryClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.current = now
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    func sleep(seconds: TimeInterval) async throws {
        // 测试里不真的等
        if Task.isCancelled { throw CancellationError() }
    }
}

// MARK: - FileSystemLocator

protocol FileSystemLocator: Sendable {
    var applicationSupportDirectory: URL { get }
    var temporaryDirectory: URL { get }

    func ensureDirectory(at url: URL) throws
    func writeAtomically(_ data: Data, to url: URL, permissions: Int16?) throws
    func readData(at url: URL) throws -> Data
    func removeItemIfExists(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func fileExists(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func modificationDate(at url: URL) -> Date?
}

struct LiveFileSystemLocator: FileSystemLocator {
    let applicationSupportDirectory: URL
    let temporaryDirectory: URL

    init(bundleName: String = "TableLite") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.applicationSupportDirectory = base.appendingPathComponent(bundleName, isDirectory: true)
        self.temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleName, isDirectory: true)
    }

    func ensureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func writeAtomically(_ data: Data, to url: URL, permissions: Int16?) throws {
        try ensureDirectory(at: url.deletingLastPathComponent())
        // `.atomic` 写临时文件后 rename，天然避免半截文件
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func removeItemIfExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    func modificationDate(at url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}

/// 测试用：指向一个独立的临时目录，语义与 Live 实现一致。
final class InMemoryFileSystemLocator: FileSystemLocator, @unchecked Sendable {
    let root: URL
    let applicationSupportDirectory: URL
    let temporaryDirectory: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteTests-\(UUID().uuidString)", isDirectory: true)
        self.root = base
        self.applicationSupportDirectory = base.appendingPathComponent("Support", isDirectory: true)
        self.temporaryDirectory = base.appendingPathComponent("Temp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private let live = LiveFileSystemLocator()

    func ensureDirectory(at url: URL) throws { try live.ensureDirectory(at: url) }
    func writeAtomically(_ data: Data, to url: URL, permissions: Int16?) throws {
        try live.writeAtomically(data, to: url, permissions: permissions)
    }
    func readData(at url: URL) throws -> Data { try live.readData(at: url) }
    func removeItemIfExists(at url: URL) throws { try live.removeItemIfExists(at: url) }
    func moveItem(at source: URL, to destination: URL) throws { try live.moveItem(at: source, to: destination) }
    func fileExists(at url: URL) -> Bool { live.fileExists(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try live.contentsOfDirectory(at: url) }
    func modificationDate(at url: URL) -> Date? { live.modificationDate(at: url) }
}

// MARK: - CredentialStore
//
// 密码 / passphrase 只进 Keychain，禁止写进 JSON / UserDefaults。
// 见 docs/tech-designs/02-persistence.md §3。

struct CredentialKey: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case mysqlPassword
        case sshPassword
        case sshPassphrase

        var serviceSuffix: String {
            switch self {
            case .mysqlPassword: return "mysql-password"
            case .sshPassword: return "ssh-password"
            case .sshPassphrase: return "ssh-passphrase"
            }
        }
    }

    var kind: Kind
    var connectionID: UUID
}

protocol CredentialStore: Sendable {
    func store(_ secret: String, for key: CredentialKey) throws
    func retrieve(_ key: CredentialKey) throws -> String?
    func delete(_ key: CredentialKey) throws
    /// 删除连接时连带删除三个条目
    func deleteAll(connectionID: UUID) throws
}

extension CredentialStore {
    func deleteAll(connectionID: UUID) throws {
        for kind in [CredentialKey.Kind.mysqlPassword, .sshPassword, .sshPassphrase] {
            try delete(CredentialKey(kind: kind, connectionID: connectionID))
        }
    }
}

/// 测试 / 预览用内存实现。
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CredentialKey: String] = [:]

    init(secrets: [CredentialKey: String] = [:]) {
        self.storage = secrets
    }

    func store(_ secret: String, for key: CredentialKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = secret
    }

    func retrieve(_ key: CredentialKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func delete(_ key: CredentialKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }

    func deleteAll(connectionID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        for key in storage.keys where key.connectionID == connectionID {
            storage[key] = nil
        }
    }
}
