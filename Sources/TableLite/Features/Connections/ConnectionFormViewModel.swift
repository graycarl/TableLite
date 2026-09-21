import Foundation
import os

// MARK: - ConnectionFormViewModel

/// 连接配置表单的状态与校验。见 `specs/01-connections.md` §2。
///
/// - 校验规则与字段说明完全按 spec；
/// - 密码只经 `AppEnvironment.credentials` 读写 Keychain；
/// - 视图禁止直接读写 UserDefaults / Keychain / FileManager。
@MainActor
final class ConnectionFormViewModel: ObservableObject {

    // MARK: 基本信息

    @Published var name: String
    @Published var color: ConnectionColor
    @Published var readOnly: Bool

    // MARK: MySQL

    @Published var host: String
    @Published var port: String
    @Published var user: String
    @Published var password: String
    @Published var database: String
    @Published var charset: String
    @Published var useSSL: Bool
    @Published var skipCertificateVerification: Bool
    @Published var connectTimeout: String
    @Published var queryTimeout: String
    @Published var keepAlive: Bool
    @Published var keepAliveInterval: String

    // MARK: SSH

    @Published var sshEnabled: Bool
    @Published var sshHost: String
    @Published var sshPort: String
    @Published var sshUser: String
    @Published var authMethod: SSHAuthMethod
    @Published var privateKeyPath: String
    @Published var useSSHConfigAlias: Bool
    @Published var jumpHost: String

    // MARK: 密码

    @Published var savePasswordToKeychain: Bool
    @Published private(set) var hasSavedPassword: Bool

    // MARK: 反馈

    @Published var alertMessage: String?
    @Published var connectFailure: ConnectionFailureInfo?

    let isNewConnection: Bool

    private(set) var isNew: Bool
    private var connectionID: UUID
    private var createdAt: Date
    private let env: AppEnvironment
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

    // MARK: 初始化

    init(env: AppEnvironment, target: ConnectionSheets.Target) {
        self.env = env
        self.isNewConnection = target.isNew
        self.isNew = target.isNew

        let connection = target.connection
        self.connectionID = connection.id
        self.createdAt = connection.createdAt

        name = connection.name
        color = connection.color
        readOnly = connection.readOnly

        host = connection.mysql.host
        port = String(connection.mysql.port)
        user = connection.mysql.user
        database = connection.mysql.database
        charset = connection.mysql.charset
        useSSL = connection.mysql.useSSL
        skipCertificateVerification = connection.mysql.skipCertificateVerification
        connectTimeout = String(connection.mysql.connectTimeout)
        queryTimeout = String(connection.mysql.queryTimeout)
        keepAlive = connection.mysql.keepAlive
        keepAliveInterval = String(connection.mysql.keepAliveInterval)

        sshEnabled = connection.ssh.enabled
        sshHost = connection.ssh.host
        sshPort = String(connection.ssh.port)
        sshUser = connection.ssh.user
        authMethod = connection.ssh.authMethod
        privateKeyPath = connection.ssh.privateKeyPath
        useSSHConfigAlias = connection.ssh.useSSHConfigAlias
        jumpHost = connection.ssh.jumpHost

        savePasswordToKeychain = true
        hasSavedPassword = false

        let key = CredentialKey(kind: .mysqlPassword, connectionID: connection.id)
        if let saved = try? env.credentials.retrieve(key) {
            hasSavedPassword = true
            password = saved
        } else {
            password = ""
        }
    }

    // MARK: 字符集

    var charsetOptions: [String] {
        let base = ["utf8mb4", "utf8mb3", "utf8", "latin1", "gbk", "big5", "ascii"]
        let current = charset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty, !base.contains(current) else { return base }
        return [current] + base
    }

    // MARK: 校验
    //
    // 规则见 `specs/01-connections.md` §2「表单校验」：
    // 主机、用户不能为空；端口 1–65535；超时正整数；私钥文件必须存在。

    var nameError: String? {
        trimmed(name).isEmpty ? "名称不能为空" : nil
    }

    var hostError: String? {
        trimmed(host).isEmpty ? "主机不能为空" : nil
    }

    var userError: String? {
        trimmed(user).isEmpty ? "用户不能为空" : nil
    }

    var portError: String? {
        validatePort(port)
    }

    var connectTimeoutError: String? {
        validatePositive(connectTimeout, name: "连接超时")
    }

    var queryTimeoutError: String? {
        validatePositive(queryTimeout, name: "查询超时")
    }

    var keepAliveIntervalError: String? {
        keepAlive ? validatePositive(keepAliveInterval, name: "心跳间隔") : nil
    }

    var sshPortError: String? {
        sshEnabled ? validatePort(sshPort) : nil
    }

    var privateKeyError: String? {
        guard sshEnabled, authMethod == .privateKey else { return nil }
        let path = trimmed(privateKeyPath)
        guard !path.isEmpty else { return "请选择私钥文件" }
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return env.fileSystem.fileExists(at: url) ? nil : "私钥文件不存在"
    }

    var isValid: Bool {
        nameError == nil
            && hostError == nil
            && userError == nil
            && portError == nil
            && connectTimeoutError == nil
            && queryTimeoutError == nil
            && keepAliveIntervalError == nil
            && sshPortError == nil
            && privateKeyError == nil
    }

    // MARK: 组装

    func makeConnection() -> Connection {
        var connection = Connection()
        connection.id = connectionID
        connection.name = trimmed(name)
        connection.color = color
        connection.readOnly = readOnly

        var mysql = MySQLConnectConfig()
        mysql.host = trimmed(host)
        mysql.port = Int(trimmed(port)) ?? 3306
        mysql.user = trimmed(user)
        mysql.database = trimmed(database)
        mysql.charset = charset
        mysql.useSSL = useSSL
        mysql.skipCertificateVerification = skipCertificateVerification
        mysql.connectTimeout = Int(trimmed(connectTimeout)) ?? 10
        mysql.queryTimeout = Int(trimmed(queryTimeout)) ?? 300
        mysql.keepAlive = keepAlive
        mysql.keepAliveInterval = Int(trimmed(keepAliveInterval)) ?? 30
        connection.mysql = mysql

        var ssh = SSHTunnelConfig()
        ssh.enabled = sshEnabled
        ssh.host = trimmed(sshHost)
        ssh.port = Int(trimmed(sshPort)) ?? 22
        ssh.user = trimmed(sshUser)
        ssh.authMethod = authMethod
        ssh.privateKeyPath = trimmed(privateKeyPath)
        ssh.useSSHConfigAlias = useSSHConfigAlias
        ssh.jumpHost = trimmed(jumpHost)
        connection.ssh = ssh

        connection.createdAt = createdAt
        connection.updatedAt = Date()
        return connection
    }

    var resolvedPassword: String? {
        password.isEmpty ? nil : password
    }

    // MARK: 密码

    /// 「清除已保存密码」：删除 Keychain 条目并清空输入框。
    func clearSavedPassword() {
        let key = CredentialKey(kind: .mysqlPassword, connectionID: connectionID)
        do {
            try env.credentials.delete(key)
            hasSavedPassword = false
            password = ""
        } catch {
            logger.error("清除已保存密码失败：\(String(describing: error), privacy: .public)")
            alertMessage = "清除已保存密码失败：\(error.localizedDescription)"
        }
    }

    // MARK: 保存

    /// 保存连接配置。密码按「保存到钥匙串」勾选状态写入 / 删除。
    @discardableResult
    func save() -> Bool {
        guard isValid else { return false }
        do {
            let connection = makeConnection()
            if isNew {
                try env.connections.add(connection)
                isNew = false
            } else {
                try env.connections.update(connection)
            }
            try persistPassword()
            return true
        } catch {
            logger.error("保存连接失败：\(String(describing: error), privacy: .public)")
            alertMessage = "保存连接失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 保存并连接。失败时保留表单内容并给出错误面板。
    @discardableResult
    func saveAndConnect() async -> Bool {
        guard save() else { return false }
        return await attemptConnect(makeConnection(), password: resolvedPassword)
    }

    func retryConnect(_ info: ConnectionFailureInfo) async {
        _ = await attemptConnect(info.connection, password: info.password)
    }

    private func attemptConnect(_ connection: Connection, password: String?) async -> Bool {
        do {
            try await env.sessionManager.connect(connection, password: password)
            return true
        } catch {
            logger.error("连接失败：\(String(describing: error), privacy: .public)")
            connectFailure = ConnectionFailureInfo.make(error: error,
                                                        connection: connection,
                                                        password: password)
            return false
        }
    }

    // MARK: 私有

    private func persistPassword() throws {
        let key = CredentialKey(kind: .mysqlPassword, connectionID: connectionID)
        guard savePasswordToKeychain else { return }
        if password.isEmpty {
            try env.credentials.delete(key)
            hasSavedPassword = false
        } else {
            try env.credentials.store(password, for: key)
            hasSavedPassword = true
        }
    }

    private func validatePort(_ text: String) -> String? {
        guard let value = Int(trimmed(text)), (1...65535).contains(value) else {
            return "端口必须是 1–65535 的整数"
        }
        return nil
    }

    private func validatePositive(_ text: String, name: String) -> String? {
        guard let value = Int(trimmed(text)), value > 0 else {
            return "\(name)必须是正整数"
        }
        return nil
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
