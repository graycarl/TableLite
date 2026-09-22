import Foundation

// MARK: - 连接颜色

/// 连接在界面上用于区分的颜色。默认无色。
///
/// 需求见 `specs/01-connections.md` §2、`specs/09-readonly-mode.md` §3。
public enum ConnectionColor: String, Sendable, Codable, CaseIterable, Hashable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    /// 界面上显示的中文名。
    public var displayName: String {
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

// MARK: - MySQL 配置

/// 连接 MySQL 所需的配置。**不含密码**：密码只进 Keychain。
///
/// 字段与默认值见 `specs/01-connections.md` §2。
public struct MySQLConfig: Sendable, Codable, Equatable, Hashable {
    public var host: String
    public var port: Int
    public var user: String
    /// 可留空；留空时连接后默认选中第一个可访问的库。
    public var database: String
    public var charset: String
    /// Unix socket 路径；非空时 libmysqlclient 优先走 socket。
    public var unixSocket: String?
    public var useSSL: Bool
    public var skipCertificateVerification: Bool
    /// 连接超时（秒）。
    public var connectTimeout: Int
    /// 查询超时（秒）；超时后自动中止查询。
    public var queryTimeout: Int
    public var keepAlive: Bool
    /// 心跳间隔（秒）。
    public var keepAliveInterval: Int

    public init(
        host: String = "",
        port: Int = 3306,
        user: String = "",
        database: String = "",
        charset: String = "utf8mb4",
        unixSocket: String? = nil,
        useSSL: Bool = true,
        skipCertificateVerification: Bool = false,
        connectTimeout: Int = 10,
        queryTimeout: Int = 300,
        keepAlive: Bool = true,
        keepAliveInterval: Int = 30
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.charset = charset
        self.unixSocket = unixSocket
        self.useSSL = useSSL
        self.skipCertificateVerification = skipCertificateVerification
        self.connectTimeout = connectTimeout
        self.queryTimeout = queryTimeout
        self.keepAlive = keepAlive
        self.keepAliveInterval = keepAliveInterval
    }

    /// 连接列表里的一行摘要：`用户@主机:端口/数据库`。
    public var summary: String {
        let databasePart = database.isEmpty ? "" : "/\(database)"
        return "\(user)@\(host):\(port)\(databasePart)"
    }
}

// MARK: - SSH 配置

/// SSH 认证方式三选一。
///
/// 见 `docs/tech-designs/04-ssh-tunnel.md` §2、`specs/10-ssh-tunnel.md` §3。
public enum SSHAuthMethod: String, Sendable, Codable, CaseIterable, Hashable {
    /// 使用 `~/.ssh/config` 与 ssh-agent，完全交给系统解析。
    case sshConfigOrAgent
    /// 使用指定的私钥文件。
    case privateKey
    /// 使用 SSH 账号密码（经 `SSH_ASKPASS`）。
    case password

    public var displayName: String {
        switch self {
        case .sshConfigOrAgent: return "使用 ~/.ssh/config 与 ssh-agent"
        case .privateKey: return "使用私钥"
        case .password: return "使用密码"
        }
    }
}

/// SSH 隧道配置。**不含密码 / passphrase**：只进 Keychain。
///
/// 字段见 `specs/01-connections.md` §2 与 `specs/10-ssh-tunnel.md` §2。
public struct SSHConfig: Sendable, Codable, Equatable, Hashable {
    public var enabled: Bool
    /// 主机名 / IP；开启 `useSSHConfigAlias` 时可以是 `~/.ssh/config` 里的别名。
    public var host: String
    public var port: Int
    public var user: String
    public var authMethod: SSHAuthMethod
    /// 私钥文件路径（`authMethod == .privateKey` 时使用）。
    public var privateKeyPath: String?
    /// 完全交给系统 SSH 配置解析该主机。
    public var useSSHConfigAlias: Bool
    /// 跳板机，形如 `user@proxy:22`。
    public var jumpHost: String?

    public init(
        enabled: Bool = false,
        host: String = "",
        port: Int = 22,
        user: String = "",
        authMethod: SSHAuthMethod = .sshConfigOrAgent,
        privateKeyPath: String? = nil,
        useSSHConfigAlias: Bool = false,
        jumpHost: String? = nil
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.user = user
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.useSSHConfigAlias = useSSHConfigAlias
        self.jumpHost = jumpHost
    }
}

// MARK: - 连接

/// 一个保存的连接。**不持有密码与 passphrase**。
///
/// 模型见 `docs/tech-designs/05-session-management.md` §1，持久化见
/// `docs/tech-designs/02-persistence.md` §2。
public struct Connection: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ConnectionColor
    /// 只读标记与密码一起持久化（不进 Keychain）。
    public var isReadOnly: Bool
    public var mysql: MySQLConfig
    public var ssh: SSHConfig
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "",
        color: ConnectionColor = .none,
        isReadOnly: Bool = false,
        mysql: MySQLConfig = MySQLConfig(),
        ssh: SSHConfig = SSHConfig(),
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isReadOnly = isReadOnly
        self.mysql = mysql
        self.ssh = ssh
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 连接列表里的一行摘要。走 SSH 时追加「（经 ssh-主机）」。
    public var summary: String {
        var text = mysql.summary
        if ssh.enabled, !ssh.host.isEmpty {
            text += "（经 ssh-\(ssh.host)）"
        }
        return text
    }

    /// 复制为新连接：换 id、重置时间戳，其余字段照搬。
    public func duplicated(newName: String? = nil, now: Date = Date(timeIntervalSince1970: 0)) -> Connection {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? (name.isEmpty ? "副本" : "\(name) 副本")
        copy.createdAt = now
        copy.updatedAt = now
        return copy
    }

    // MARK: 表单校验

    /// 连接表单的校验问题。需求见 `specs/01-connections.md` §2「表单校验」。
    public enum ValidationIssue: String, Sendable, Codable, Equatable, CaseIterable {
        case emptyName
        case emptyHost
        case emptyUser
        case invalidMySQLPort
        case invalidConnectTimeout
        case invalidQueryTimeout
        case invalidKeepAliveInterval
        case emptySSHHost
        case emptySSHUser
        case invalidSSHPort
        case missingPrivateKeyPath

        /// 字段下方显示的中文提示。
        public var message: String {
            switch self {
            case .emptyName: return "请填写连接名称"
            case .emptyHost: return "请填写主机"
            case .emptyUser: return "请填写用户"
            case .invalidMySQLPort: return "端口必须是 1–65535 的整数"
            case .invalidConnectTimeout: return "连接超时必须是正整数"
            case .invalidQueryTimeout: return "查询超时必须是正整数"
            case .invalidKeepAliveInterval: return "心跳间隔必须是正整数"
            case .emptySSHHost: return "请填写 SSH 主机"
            case .emptySSHUser: return "请填写 SSH 用户"
            case .invalidSSHPort: return "SSH 端口必须是 1–65535 的整数"
            case .missingPrivateKeyPath: return "选择「使用私钥」时必须指定私钥文件"
            }
        }
    }

    public func validationIssues() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyName) }
        if mysql.host.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyHost) }
        if mysql.user.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptyUser) }
        if !(1...65535).contains(mysql.port) { issues.append(.invalidMySQLPort) }
        if mysql.connectTimeout <= 0 { issues.append(.invalidConnectTimeout) }
        if mysql.queryTimeout <= 0 { issues.append(.invalidQueryTimeout) }
        if mysql.keepAlive && mysql.keepAliveInterval <= 0 { issues.append(.invalidKeepAliveInterval) }

        if ssh.enabled {
            if ssh.host.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptySSHHost) }
            // 别名模式完全交给系统 `~/.ssh/config` 解析（主机别名、端口、用户、密钥），
            // 因此不再强制要求 ssh.user / 端口 / 私钥路径（`specs/10-ssh-tunnel.md` §3.1）。
            if !ssh.useSSHConfigAlias {
                if ssh.user.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(.emptySSHUser) }
                if !(1...65535).contains(ssh.port) { issues.append(.invalidSSHPort) }
                if ssh.authMethod == .privateKey,
                   (ssh.privateKeyPath?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                    issues.append(.missingPrivateKeyPath)
                }
            }
        }
        return issues
    }
}

// MARK: - 持久化文件

/// `connections.json` 的内容。见 `docs/tech-designs/02-persistence.md` §2、§9。
public struct ConnectionMetadataFile: Sendable, Codable, Equatable {
    /// 未知字段忽略、缺失字段取默认值；只有破坏性变更才递增版本。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var connections: [Connection]

    public init(schemaVersion: Int = ConnectionMetadataFile.currentSchemaVersion, connections: [Connection] = []) {
        self.schemaVersion = schemaVersion
        self.connections = connections
    }

    /// 反序列化时若发现残留的密码 / passphrase 字段，直接丢弃并把这些键名返回给调用方记录警告。
    ///
    /// `Connection` 本身没有这些字段，`JSONDecoder` 会自动忽略；这里额外检查原文，
    /// 以便上层能明确记一条日志（`02-persistence.md` §2）。
    public static func decode(from data: Data) throws -> (file: ConnectionMetadataFile, droppedSecretKeys: [String]) {
        let dropped = detectSecretKeys(in: data)
        let file = try JSONDecoder().decode(ConnectionMetadataFile.self, from: data)
        return (file, dropped)
    }

    /// 扫描 JSON 原文里是否存在密码类字段名（不区分大小写）。
    public static func detectSecretKeys(in data: Data) -> [String] {
        let secretNames: Set<String> = ["password", "passphrase", "sshpassword", "ssh_password", "secret"]
        func scan(_ object: Any) -> [String] {
            var found: Set<String> = []
            if let dictionary = object as? [String: Any] {
                for (key, value) in dictionary {
                    if secretNames.contains(key.lowercased()) { found.insert(key) }
                    found.formUnion(scan(value))
                }
            } else if let array = object as? [Any] {
                for element in array { found.formUnion(scan(element)) }
            }
            return found.sorted()
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return []
        }
        return scan(object)
    }
}
