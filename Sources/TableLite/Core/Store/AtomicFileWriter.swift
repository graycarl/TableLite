import Foundation

/// 「临时文件 + 原子替换」写入，以及目录 / 文件权限。
///
/// 决策见 `02-persistence.md` §2.1：写文件用临时文件 + 原子替换；目录 `0700`、文件 `0600`。
///
/// 注意：`Data.write(to:options:.atomic)` 也能原子替换，但无法保证 `0600` 权限，
/// 因此这里手写「同目录临时文件 → 设权限 → 替换」。
public enum AtomicFileWriter {

    /// 目录权限：只有当前用户可访问。
    public static let directoryPermissions = 0o700
    /// 文件权限：只有当前用户可读写。
    public static let filePermissions = 0o600

    // MARK: - 目录

    /// 确保目录存在；已存在但不是目录时抛错。
    public static func ensureDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StoreFileError.notADirectory(directory.path) }
            return
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions]
            )
        } catch {
            StoreLog.error("创建目录失败 \(directory.path)：\(error)")
            throw StoreFileError.writeFailed(directory.path)
        }
    }

    // MARK: - 写入

    /// 原子写入数据。
    public static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: filePermissions]
        ) else {
            StoreLog.error("创建临时文件失败：\(temporary.path)")
            throw StoreFileError.writeFailed(url.path)
        }
        // 部分文件系统会忽略 createFile 的 attributes，这里再设一次。
        try? fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: temporary.path)

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
            try? fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
        } catch {
            StoreLog.error("原子替换失败 \(url.path)：\(error)")
            try? fileManager.removeItem(at: temporary)
            throw StoreFileError.writeFailed(url.path)
        }
    }

    /// 原子写入文本（UTF-8）。
    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    // MARK: - 读取 / 删除

    /// 读取文件内容；文件不存在返回 `nil`。
    public static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            StoreLog.error("读取文件失败 \(url.path)：\(error)")
            throw StoreFileError.readFailed(url.path)
        }
    }

    /// 读取 UTF-8 文本；文件不存在返回 `nil`。
    public static func readText(_ url: URL) throws -> String? {
        guard let data = try read(url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除文件；不存在时静默返回（幂等）。
    public static func remove(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            StoreLog.error("删除文件失败 \(url.path)：\(error)")
            throw StoreFileError.removeFailed(url.path)
        }
    }

    /// 文件修改时间；不存在或读不到时返回 `nil`。
    public static func modificationDate(_ url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// 列出目录里的文件名（不含子目录）；目录不存在时返回空数组。
    public static func contents(of directory: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            StoreLog.warning("列目录失败 \(directory.path)：\(error)")
            return []
        }
    }

    // MARK: - 备份

    /// 把原文件另存为 `<文件名>.bak-<suffix>`（`02-persistence.md` §9：遇到不认识的版本时备份）。
    @discardableResult
    public static func backup(_ url: URL, suffix: String) throws -> URL {
        let backupURL = url.appendingPathExtension("bak-\(suffix)")
        do {
            let data = try Data(contentsOf: url)
            try write(data, to: backupURL)
            return backupURL
        } catch {
            StoreLog.error("备份文件失败 \(url.path)：\(error)")
            throw StoreFileError.writeFailed(backupURL.path)
        }
    }
}
