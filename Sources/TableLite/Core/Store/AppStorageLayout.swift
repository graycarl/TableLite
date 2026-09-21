import Foundation

/// `Application Support/TableLite/` 下的文件布局。
///
/// 决策见 `02-persistence.md` §1。**禁止硬编码路径**：根目录由 `FileSystemLocator`
/// 解析（真实运行时是 `Application Support`，单测里是临时目录）。
public struct AppStorageLayout: Sendable, Equatable {

    /// 存储根目录，通常是 `~/Library/Application Support/TableLite`。
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// 从定位器解析根目录（不存在时创建）。
    public init(locating locator: FileSystemLocator) throws {
        self.rootDirectory = try locator.storageRoot()
    }

    /// 真实运行环境的布局（`Application Support/TableLite`）。
    public static func live() throws -> AppStorageLayout {
        try AppStorageLayout(locating: LiveFileSystemLocator())
    }

    // MARK: - 文件

    /// 连接元数据（`02-persistence.md` §2）。
    public var connectionsFile: URL {
        rootDirectory.appendingPathComponent("connections.json")
    }

    /// 查询历史 SQLite 库（`02-persistence.md` §4）。
    public var historyDatabase: URL {
        rootDirectory.appendingPathComponent("history.sqlite3")
    }

    /// 会话恢复状态（`05-session-management.md` §8）。
    public var sessionFile: URL {
        rootDirectory.appendingPathComponent("session.json")
    }

    /// Console Log 落盘目录（`02-persistence.md` §5）。
    public var consoleLogDirectory: URL {
        rootDirectory.appendingPathComponent("ConsoleLogs", isDirectory: true)
    }

    /// 查询草稿目录（`05-session-management.md` §9）。
    public var draftsDirectory: URL {
        rootDirectory.appendingPathComponent("Drafts", isDirectory: true)
    }

    // MARK: - 派生路径

    /// 某个查询草稿的文件地址。文件名只含 `draftId`，编辑内容在文件里。
    public func draftFile(id: UUID) -> URL {
        draftsDirectory.appendingPathComponent("draft-\(id.uuidString.lowercased()).sql")
    }
}

extension AppStorageLayout {
    /// 从草稿文件名解析 `draftId`；不是草稿文件时返回 `nil`。
    public static func draftID(fromFileName fileName: String) -> UUID? {
        guard fileName.hasPrefix("draft-"), fileName.hasSuffix(".sql") else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: "draft-".count)
        let end = fileName.index(fileName.endIndex, offsetBy: -".sql".count)
        return UUID(uuidString: String(fileName[start..<end]))
    }
}
