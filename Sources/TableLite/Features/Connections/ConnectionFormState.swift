import Foundation

/// 连接配置表单的状态与纯逻辑（`specs/01-connections.md` §2、§3「密码处理」）。
///
/// 只负责「表单现在长什么样」以及「怎么把它变成一个 `Connection` / 一次密码写入意图」；
/// 不碰 Keychain、不碰磁盘、不弹窗，方便单测。
///
/// 校验的权威仍然是 `Connection.validationIssues()`：本类型把文本字段解析成模型后再问它，
/// 额外只补一条「私钥文件必须存在」（`specs/01-connections.md` §2「表单校验」）。
struct ConnectionFormState: Equatable {

    // MARK: - 密码写入意图

    /// 保存表单时对钥匙串里 MySQL 密码的处置。
    ///
    /// 需求见 `specs/01-connections.md` §2「密码处理」。保存时「密码框为空」等价于
    /// 「删除钥匙串条目」；勾选「保存到钥匙串」才持久化，不勾选只在本次运行期间记住。
    enum PasswordUpdate: Equatable {
        /// 写入钥匙串。
        case set(String)
        /// 不写钥匙串，仅在本次运行内使用；同时清掉旧条目。
        case sessionOnly(String)
        /// 删除钥匙串里的条目（密码框为空，或用户点了「清除已保存密码」）。
        case clear
    }

    // MARK: - 身份

    /// 表单对应的连接 id：新建时生成一次并保持稳定，编辑时沿用原 id。
    var connectionID: UUID = UUID()
    /// 编辑模式下的原始连接（时间戳与身份用）；新建时为 nil。
    private(set) var original: Connection?

    var isEditing: Bool { original != nil }

    // MARK: - 基本信息

    var name: String = ""
    var color: ConnectionColor = .none
    var isReadOnly: Bool = false

    // MARK: - MySQL

    var host: String = ""
    var portText: String = "3306"
    var user: String = ""
    var database: String = ""
    var charset: String = "utf8mb4"
    var unixSocket: String = ""
    var useSSL: Bool = true
    var skipCertificateVerification: Bool = false
    var connectTimeoutText: String = "10"
    var queryTimeoutText: String = "300"
    var keepAlive: Bool = true
    var keepAliveIntervalText: String = "30"

    // MARK: - 密码

    var password: String = ""
    var savePasswordToKeychain: Bool = true
    /// 钥匙串里当前是否已有保存的密码（决定是否显示「清除已保存密码」）。
    var hasStoredPassword: Bool = false
    /// 用户点了「清除已保存密码」。
    var clearStoredPasswordRequested: Bool = false

    // MARK: - SSH

    var sshEnabled: Bool = false
    var sshHost: String = ""
    var sshPortText: String = "22"
    var sshUser: String = ""
    var sshAuthMethod: SSHAuthMethod = .sshConfigOrAgent
    var sshPrivateKeyPath: String = ""
    var sshUseConfigAlias: Bool = false
    var sshJumpHost: String = ""
    /// SSH 账号密码（`authMethod == .password`）。只进钥匙串，不落配置文件。
    var sshPassword: String = ""
    /// 钥匙串里当前是否已有保存的 SSH 密码（决定编辑时是否回填）。
    var hasStoredSSHPassword: Bool = false

    // MARK: - 初始化

    /// 新建连接的空白表单。
    ///
    /// 三个默认值可由偏好覆盖（`specs/11-preferences.md` §2）：新建连接时的默认查询超时、
    /// 默认「保持连接活跃」、心跳间隔。无参调用时与 `specs/01-connections.md` §2 的初值一致。
    init(queryTimeout: Int = 300, keepAlive: Bool = true, keepAliveInterval: Int = 30) {
        queryTimeoutText = String(queryTimeout)
        self.keepAlive = keepAlive
        keepAliveIntervalText = String(keepAliveInterval)
    }

    /// 编辑已有连接：回填全部字段（密码由调用方从钥匙串取出后另行传入）。
    init(connection: Connection) {
        original = connection
        connectionID = connection.id

        name = connection.name
        color = connection.color
        isReadOnly = connection.isReadOnly

        host = connection.mysql.host
        portText = String(connection.mysql.port)
        user = connection.mysql.user
        database = connection.mysql.database
        charset = connection.mysql.charset
        unixSocket = connection.mysql.unixSocket ?? ""
        useSSL = connection.mysql.useSSL
        skipCertificateVerification = connection.mysql.skipCertificateVerification
        connectTimeoutText = String(connection.mysql.connectTimeout)
        queryTimeoutText = String(connection.mysql.queryTimeout)
        keepAlive = connection.mysql.keepAlive
        keepAliveIntervalText = String(connection.mysql.keepAliveInterval)

        sshEnabled = connection.ssh.enabled
        sshHost = connection.ssh.host
        sshPortText = String(connection.ssh.port)
        sshUser = connection.ssh.user
        sshAuthMethod = connection.ssh.authMethod
        sshPrivateKeyPath = connection.ssh.privateKeyPath ?? ""
        sshUseConfigAlias = connection.ssh.useSSHConfigAlias
        sshJumpHost = connection.ssh.jumpHost ?? ""
    }

    // MARK: - 字段 → 模型

    /// 把表单解析成 `Connection`。非法数字统一解析成 `-1`，交给
    /// `Connection.validationIssues()` 报错，保证「表单校验」只有一份实现。
    func makeConnection(now: Date) -> Connection {
        var connection = buildBase()
        connection.id = connectionID
        connection.createdAt = original?.createdAt ?? now
        connection.updatedAt = now
        return connection
    }

    private func buildBase() -> Connection {
        var connection = Connection()
        connection.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.color = color
        connection.isReadOnly = isReadOnly
        connection.mysql = MySQLConfig(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Self.intValue(portText),
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            charset: charset.trimmingCharacters(in: .whitespacesAndNewlines),
            unixSocket: Self.normalizedOptional(unixSocket),
            useSSL: useSSL,
            skipCertificateVerification: skipCertificateVerification,
            connectTimeout: Self.intValue(connectTimeoutText),
            queryTimeout: Self.intValue(queryTimeoutText),
            keepAlive: keepAlive,
            keepAliveInterval: Self.intValue(keepAliveIntervalText)
        )
        connection.ssh = SSHConfig(
            enabled: sshEnabled,
            host: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Self.intValue(sshPortText),
            user: sshUser.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: sshAuthMethod,
            privateKeyPath: Self.normalizedOptional(sshPrivateKeyPath),
            useSSHConfigAlias: sshUseConfigAlias,
            jumpHost: Self.normalizedOptional(sshJumpHost)
        )
        return connection
    }

    // MARK: - 校验

    /// 表单的全部校验问题。`fileExists` 只在「使用私钥」时被调用。
    func issues(fileExists: (String) -> Bool) -> [ConnectionFormIssue] {
        var issues = buildBase().validationIssues().map(ConnectionFormIssue.validation)
        if sshEnabled, !sshUseConfigAlias, sshAuthMethod == .privateKey {
            let path = sshPrivateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, !fileExists(path) {
                issues.append(.privateKeyFileMissing(path))
            }
        }
        return issues
    }

    // MARK: - 密码

    /// 保存表单时对钥匙串的处置意图。
    var passwordUpdate: PasswordUpdate {
        if clearStoredPasswordRequested { return .clear }
        if password.isEmpty { return .clear }
        if savePasswordToKeychain { return .set(password) }
        return .sessionOnly(password)
    }

    /// 「测试连接」「保存并连接」时直接使用的密码；`nil` 表示让连接流程去钥匙串取。
    var connectionPassword: String? {
        switch passwordUpdate {
        case .clear:
            return nil
        case .set(let value), .sessionOnly(let value):
            return value
        }
    }

    // MARK: - SSH 密码

    /// 保存表单时对钥匙串里 SSH 密码的处置意图。
    ///
    /// `specs/10-ssh-tunnel.md` §3.3：密码认证的密码保存在系统钥匙串里。
    /// 密码框为空（或编辑时被清空）等价于删除钥匙串条目。
    var sshPasswordUpdate: PasswordUpdate {
        if sshPassword.isEmpty { return .clear }
        return .set(sshPassword)
    }

    /// 测试 / 保存并连接时直接传给会话的 SSH 密码；`nil` 表示去钥匙串取。
    var connectionSSHPassword: String? {
        switch sshPasswordUpdate {
        case .clear:
            return nil
        case .set(let value), .sessionOnly(let value):
            return value
        }
    }

    // MARK: - 解析辅助

    /// 合法整数；解析失败返回 `-1`，让 `Connection.validationIssues()` 统一报错。
    static func intValue(_ text: String) -> Int {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// 空白字符串视为「未填写」。
    static func normalizedOptional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 字符集下拉里提供的常用值；当前值不在列表时由界面补进去。
    static let commonCharsets = [
        "utf8mb4", "utf8mb3", "utf8", "latin1", "ascii", "binary", "gbk", "gb18030", "big5",
    ]
}

// MARK: - 表单校验问题

/// 表单要显示在字段下方的红色提示。
///
/// 绝大多数来自 `Connection.ValidationIssue`；`privateKeyFileMissing` 是表单补的
/// 「文件必须存在」检查（`specs/01-connections.md` §2）。
enum ConnectionFormIssue: Equatable, Identifiable {

    /// 提示挂在哪个字段下方。
    enum Field: String, Equatable {
        case name
        case host
        case user
        case mysqlPort
        case connectTimeout
        case queryTimeout
        case keepAliveInterval
        case sshHost
        case sshUser
        case sshPort
        case privateKeyPath
    }

    case validation(Connection.ValidationIssue)
    case privateKeyFileMissing(String)

    /// 一个字段最多一条提示，字段名即身份。
    var id: String { field.rawValue }

    var field: Field {
        switch self {
        case .validation(let issue):
            switch issue {
            case .emptyName: return .name
            case .emptyHost: return .host
            case .emptyUser: return .user
            case .invalidMySQLPort: return .mysqlPort
            case .invalidConnectTimeout: return .connectTimeout
            case .invalidQueryTimeout: return .queryTimeout
            case .invalidKeepAliveInterval: return .keepAliveInterval
            case .emptySSHHost: return .sshHost
            case .emptySSHUser: return .sshUser
            case .invalidSSHPort: return .sshPort
            case .missingPrivateKeyPath: return .privateKeyPath
            }
        case .privateKeyFileMissing:
            return .privateKeyPath
        }
    }

    var message: String {
        switch self {
        case .validation(let issue):
            return issue.message
        case .privateKeyFileMissing(let path):
            return "私钥文件不存在：\(path)"
        }
    }
}
