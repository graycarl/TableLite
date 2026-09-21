import Foundation

// MARK: - 文件

/// 文件读写失败。文案面向日志与排查，不直接上界面（需要上界面时由上层改写）。
public enum StoreFileError: Error, LocalizedError, Equatable {
    case notADirectory(String)
    case writeFailed(String)
    case readFailed(String)
    case removeFailed(String)
    case listFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): return "路径不是目录：\(path)"
        case .writeFailed(let path): return "写入文件失败：\(path)"
        case .readFailed(let path): return "读取文件失败：\(path)"
        case .removeFailed(let path): return "删除文件失败：\(path)"
        case .listFailed(let path): return "列目录失败：\(path)"
        }
    }
}

// MARK: - 连接元数据

/// 连接元数据读写失败。
public enum ConnectionStoreError: Error, LocalizedError, Equatable {
    case encodingFailed
    /// 清除钥匙串凭据失败。此时连接**保留**，用户可以重试删除。
    case credentialCleanupFailed(UUID)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "连接配置写入失败，请检查磁盘空间后重试。"
        case .credentialCleanupFailed:
            return "清除钥匙串里的密码失败，连接仍然保留，请重试删除。"
        }
    }
}

// MARK: - 凭据

/// 钥匙串操作失败。`OSStatus` 直接来自 Security.framework。
public enum CredentialStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    /// 条目存在但内容不是合法的 UTF-8 文本。
    case malformedValue(CredentialKind)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "钥匙串操作失败（OSStatus \(status)）"
        case .malformedValue(let kind): return "钥匙串里的\(kind.displayName)不是合法的 UTF-8 文本"
        }
    }
}

// MARK: - SQLite

/// libsqlite3 调用失败。
public enum StoreDatabaseError: Error, LocalizedError, Equatable {
    case sqlite(code: Int32, message: String)
    case closed
    case bindingFailed

    public var errorDescription: String? {
        switch self {
        case .sqlite(let code, let message): return "数据库错误（\(code)）：\(message)"
        case .closed: return "数据库连接已关闭"
        case .bindingFailed: return "SQL 参数绑定失败"
        }
    }
}
