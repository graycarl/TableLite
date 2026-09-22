import Foundation

/// 存储位置的注入点。
///
/// 决策见 `15-testing.md` §3：`Application Support` 路径必须可注入，测试指到临时目录。
/// 业务代码不得直接拼 `Application Support` 路径。
public protocol FileSystemLocator: Sendable {

    /// 返回存储根目录（`Application Support/TableLite`），不存在时创建（目录权限 `0700`）。
    func storageRoot() throws -> URL
}

// MARK: - 真实实现

/// 真实运行环境：`~/Library/Application Support/TableLite`。
///
/// 这是唯一允许直接使用 `FileManager.default` 解析 Application Support 的地方。
public struct LiveFileSystemLocator: FileSystemLocator {

    /// 目录名。
    public static let directoryName = "TableLite"

    public init() {}

    public func storageRoot() throws -> URL {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let root = base.appendingPathComponent(Self.directoryName, isDirectory: true)
            try AtomicFileWriter.ensureDirectory(root)
            return root
        } catch let error as StoreFileError {
            throw error
        } catch {
            StoreLog.error("解析 Application Support 目录失败：\(error)")
            throw StoreFileError.writeFailed("Application Support/\(Self.directoryName)")
        }
    }
}

// MARK: - 测试实现

/// 单测 / 预览用：把根目录指向一个显式目录（通常是临时目录）。
///
/// 命名上对应 `15-testing.md` §3 的「InMemory 实现」；这里仍走真实文件系统，
/// 因为原子替换与权限本身就是被测对象。
public struct TemporaryFileSystemLocator: FileSystemLocator {

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// 在系统临时目录下生成一个唯一根目录。
    public static func unique() -> TemporaryFileSystemLocator {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLite-\(UUID().uuidString)", isDirectory: true)
        return TemporaryFileSystemLocator(rootDirectory: url)
    }

    public func storageRoot() throws -> URL {
        try AtomicFileWriter.ensureDirectory(rootDirectory)
        return rootDirectory
    }
}
