import Foundation

// MARK: - MySQL 连接配置

struct MySQLConnectConfig: Hashable, Sendable, Codable {
    var host: String = "127.0.0.1"
    var port: Int = 3306
    var user: String = "root"
    /// 空字符串表示不指定库（连接后默认选中第一个可访问的库）
    var database: String = ""
    var charset: String = "utf8mb4"
    var useSSL: Bool = true
    var skipCertificateVerification: Bool = false
    /// 秒
    var connectTimeout: Int = 10
    /// 秒
    var queryTimeout: Int = 300
    var keepAlive: Bool = true
    /// 秒
    var keepAliveInterval: Int = 30
}

// MARK: - SSH 隧道配置

enum SSHAuthMethod: String, Codable, Hashable, Sendable, CaseIterable {
    /// 使用 ~/.ssh/config 与 ssh-agent
    case config
    /// 使用私钥文件
    case privateKey
    /// 使用密码
    case password

    var displayName: String {
        switch self {
        case .config: return "使用 ~/.ssh/config 与 ssh-agent"
        case .privateKey: return "使用私钥"
        case .password: return "使用密码"
        }
    }
}

struct SSHTunnelConfig: Hashable, Sendable, Codable {
    var enabled: Bool = false
    var host: String = ""
    var port: Int = 22
    var user: String = ""
    var authMethod: SSHAuthMethod = .config
    var privateKeyPath: String = ""
    /// 勾选后完全交给系统 SSH 配置解析主机（别名、端口、用户、密钥）
    var useSSHConfigAlias: Bool = false
    /// 形如 `user@proxy:22`
    var jumpHost: String = ""
}

// MARK: - 连接

enum ConnectionColor: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "无色"
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .gray: return "灰"
        }
    }
}

struct Connection: Identifiable, Hashable, Sendable, Codable {
    var id: UUID = UUID()
    var name: String = ""
    var color: ConnectionColor = .none
    var readOnly: Bool = false
    var mysql: MySQLConnectConfig = .init()
    var ssh: SSHTunnelConfig = .init()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 连接列表里的一行摘要：`用户@主机:端口/数据库（经 ssh-主机）`
    var summary: String {
        var text = "\(mysql.user)@\(mysql.host):\(mysql.port)"
        if !mysql.database.isEmpty {
            text += "/\(mysql.database)"
        }
        if ssh.enabled {
            text += "（经 \(ssh.host.isEmpty ? "SSH" : ssh.host)）"
        }
        return text
    }
}

// MARK: - 服务器信息

struct ServerInfo: Hashable, Sendable {
    var version: String
    var hostInfo: String
    var charset: String
    var collation: String
    var sqlMode: String
}

// MARK: - 错误

/// 服务器返回的错误。**原样保留** `code` / `sqlState` / `message`，不做翻译。
/// 见 docs/tech-designs/01-architecture.md §4、specs/12-feedback.md §5。
struct MySQLServerError: Error, Hashable, Sendable {
    var code: UInt32
    var sqlState: String
    var message: String
    /// 出错的语句（前 200 字符）
    var sql: String?

    /// 取消 / 超时（服务器中断）不算未知错误。
    var isCancelled: Bool { code == 1317 || code == 1927 }

    /// 连接已断开
    var isConnectionLost: Bool { code == 2006 || code == 2013 }

    /// `[错误 1062] SQLSTATE 23000` + 原文
    var formatted: String {
        var text = "[错误 \(code)] SQLSTATE \(sqlState)"
        if !message.isEmpty {
            text += "\n\(message)"
        }
        return text
    }

    /// 常见错误码附带的一句中文说明，见 specs/12-feedback.md §5。
    var chineseHint: String? {
        switch code {
        case 1045: return "请检查用户名与密码。"
        case 1049: return "请检查连接配置里的数据库名，或留空。"
        case 1130: return "该账号不允许从当前 IP 连接，请检查数据库的访问白名单。"
        case 1062: return "有一行的值与已有数据重复。"
        case 1064: return "请检查这条语句。"
        case 1205: return "有其他事务长时间持有锁，稍后重试。"
        case 1213: return "事务已被回滚，请重试。"
        case 2006, 2013: return "连接已断开，请手动重新连接。"
        default: return nil
        }
    }
}

enum ConnectStep: String, Hashable, Sendable {
    case sshTunnel
    case mysql
    case serverInfo

    var displayName: String {
        switch self {
        case .sshTunnel: return "SSH 隧道"
        case .mysql: return "MySQL 连接"
        case .serverInfo: return "读取服务器信息"
        }
    }
}

enum MySQLError: Error, Hashable, Sendable {
    case notConnected
    /// 建立连接的某一步失败。`detail` 是底层原始输出（例如 SSH 的 stderr）。
    case connect(step: ConnectStep, message: String, detail: String?)
    case server(MySQLServerError)
    case cancelled
    case timeout
    case connectionLost(MySQLServerError?)
    case unsupported(String)
    case internalError(String)

    var serverError: MySQLServerError? {
        if case .server(let error) = self { return error }
        if case .connectionLost(let error) = self { return error }
        return nil
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        if case .timeout = self { return true }
        return serverError?.isCancelled ?? false
    }

    /// 面向用户的一行标题。
    var title: String {
        switch self {
        case .notConnected: return "尚未连接数据库"
        case .connect(let step, _, _): return "\(step.displayName)失败"
        case .server(let error):
            return error.isCancelled ? "查询已取消" : "服务器返回错误"
        case .cancelled: return "查询已取消"
        case .timeout: return "查询超时"
        case .connectionLost: return "连接已断开"
        case .unsupported(let text): return text
        case .internalError(let text): return text
        }
    }
}

// MARK: - SQL 字面量转义

/// 生成 SQL 字面量需要的转义能力。
///
/// 字符串必须经 `mysql_real_escape_string`（随连接 charset / sql_mode 变化），
/// 因此由 `MySQLSession` 提供闭包。纯函数 `SQLValueLiteral` 只负责拼装。
/// 见 docs/tech-designs/03-mysql-layer.md §1、§4.2。
struct SQLValueLiteralizer: Sendable {
    var charsetName: String
    /// 转义字符串内容（不含首尾引号）
    var escape: @Sendable (String) async -> String

    /// 没有连接时（单测 / 预览占位）的保守实现：转义 `'` `"` `\` 与 `\0`。
    static let conservative = SQLValueLiteralizer(
        charsetName: "utf8mb4",
        escape: { text in
            var output = ""
            output.reserveCapacity(text.count)
            for scalar in text.unicodeScalars {
                switch scalar {
                case "'", "\"", "\\":
                    output.append("\\")
                    output.append(Character(scalar))
                case "\0":
                    output.append("\\0")
                default:
                    output.unicodeScalars.append(scalar)
                }
            }
            return output
        }
    )

    /// charset 非 utf8 系时给字符串字面量加 introducer，避免服务器按别的字符集解释。
    var needsIntroducer: Bool {
        let name = charsetName.lowercased()
        return !(name.hasPrefix("utf8") || name.hasPrefix("utf-8"))
    }
}
