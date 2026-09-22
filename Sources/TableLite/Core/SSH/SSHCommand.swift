import Foundation

// MARK: - 命令

/// 一条已经拼装好的子进程命令。
///
/// 密码与私钥口令**绝不进入参数**（只经环境变量传给 askpass，见 `SSHAskpass`），
/// 因此 `commandLine` 可以安全地写进 Console Log。
public struct SSHCommand: Sendable, Equatable {
    public var executablePath: String
    public var arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }

    /// 供日志/测试展示的完整命令行。
    public var commandLine: String {
        ([executablePath] + arguments).joined(separator: " ")
    }
}

// MARK: - 拼装参数

/// `/usr/bin/ssh` 参数的可调项。默认值即产品行为，测试可覆盖。
public struct SSHCommandOptions: Sendable, Equatable {
    public var executablePath: String
    /// `-o ConnectTimeout=`（秒）。
    public var connectTimeoutSeconds: Int
    /// `-o ServerAliveInterval=`（秒）。
    public var serverAliveIntervalSeconds: Int
    /// `-o ServerAliveCountMax=`。
    public var serverAliveCountMax: Int
    /// 追加 `-v`，把详细输出打到 stderr（stderr 由 `SSHTunnel` 捕获）。
    public var verbose: Bool

    public init(
        executablePath: String = SSHCommandBuilder.defaultExecutablePath,
        connectTimeoutSeconds: Int = SSHCommandBuilder.defaultConnectTimeoutSeconds,
        serverAliveIntervalSeconds: Int = SSHCommandBuilder.defaultServerAliveIntervalSeconds,
        serverAliveCountMax: Int = SSHCommandBuilder.defaultServerAliveCountMax,
        verbose: Bool = false
    ) {
        self.executablePath = executablePath
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.serverAliveIntervalSeconds = serverAliveIntervalSeconds
        self.serverAliveCountMax = serverAliveCountMax
        self.verbose = verbose
    }

    public static let `default` = SSHCommandOptions()
}

/// 把 `SSHConfig` 拼成 `/usr/bin/ssh` 的完整参数列表。
///
/// 纯函数，可单元测试；见 `docs/tech-designs/04-ssh-tunnel.md` §3、§5、
/// `specs/10-ssh-tunnel.md` §3。
public enum SSHCommandBuilder {

    public static let defaultExecutablePath = "/usr/bin/ssh"
    public static let defaultSSHPort = 22
    public static let defaultConnectTimeoutSeconds = 15
    public static let defaultServerAliveIntervalSeconds = 15
    public static let defaultServerAliveCountMax = 3
    /// 首次连接自动接受新主机指纹；指纹变化时 ssh 会失败，不静默接受（L8）。
    public static let strictHostKeyChecking = "accept-new"

    /// 本地转发绑定的地址。只绑回环，避免局域网可访问（`04` §4）。
    public static let localBindHost = "127.0.0.1"

    /// 参数顺序固定，便于测试与排查。
    ///
    /// `useSSHConfigAlias == true` 时按 `specs/10-ssh-tunnel.md` §3.1 交给系统
    /// `~/.ssh/config`：不带 `-p` / `-i`，目标只写别名（用户、端口、密钥由 config 决定）。
    /// 固定 `-o` 选项仍然传入，它们会覆盖 config 里的同名项。
    ///
    /// 关于 `BatchMode`（文档未明确，属本模块补充决策）：
    /// - `sshConfigOrAgent` / 别名模式：加 `-o BatchMode=yes`，无 tty 时不要挂在交互提问上；
    /// - `privateKey` 与 `password`：**不加**，否则会禁止 askpass 应答口令 / 密码。
    public static func build(
        ssh: SSHConfig,
        localPort: UInt16,
        remoteHost: String,
        remotePort: Int,
        options: SSHCommandOptions = .default
    ) throws -> SSHCommand {
        let host = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw SSHTunnelError.invalidConfiguration(reason: "SSH 主机为空")
        }
        guard localPort > 0 else {
            throw SSHTunnelError.invalidConfiguration(reason: "本地端口无效")
        }
        let remote = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            throw SSHTunnelError.invalidConfiguration(reason: "MySQL 主机为空")
        }
        guard (1...65535).contains(remotePort) else {
            throw SSHTunnelError.invalidConfiguration(reason: "MySQL 端口无效")
        }

        let usesAlias = ssh.useSSHConfigAlias
        let effectiveAuth: SSHAuthMethod = usesAlias ? .sshConfigOrAgent : ssh.authMethod

        var arguments: [String] = []

        // 只做端口转发，不执行远端命令。
        arguments.append(contentsOf: ["-N"])
        // -L [bind_address:]port:host:hostport；远端是 IPv6 字面量时加方括号。
        arguments.append(contentsOf: [
            "-L",
            "\(localBindHost):\(localPort):\(bracketedIfIPv6(remote)):\(remotePort)",
        ])

        // 隧道本身必需的固定选项，会覆盖 ~/.ssh/config 里的同名项。
        arguments.append(contentsOf: ["-o", "ExitOnForwardFailure=yes"])
        arguments.append(contentsOf: ["-o", "ServerAliveInterval=\(options.serverAliveIntervalSeconds)"])
        arguments.append(contentsOf: ["-o", "ServerAliveCountMax=\(options.serverAliveCountMax)"])
        arguments.append(contentsOf: ["-o", "ConnectTimeout=\(options.connectTimeoutSeconds)"])
        arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=\(strictHostKeyChecking)"])

        // 跳板机：显式填写时透传；为空则由 ~/.ssh/config 的 ProxyJump 决定。
        if let jumpHost = ssh.jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines), !jumpHost.isEmpty {
            arguments.append(contentsOf: ["-J", jumpHost])
        }

        // 非默认端口才传 -p；别名模式完全不传，交给 config。
        if !usesAlias {
            guard (1...65535).contains(ssh.port) else {
                throw SSHTunnelError.invalidConfiguration(reason: "SSH 端口无效")
            }
            if ssh.port != defaultSSHPort {
                arguments.append(contentsOf: ["-p", "\(ssh.port)"])
            }
        }

        switch effectiveAuth {
        case .privateKey:
            let keyPath = ssh.privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !keyPath.isEmpty else {
                throw SSHTunnelError.invalidConfiguration(reason: "使用私钥认证时必须指定私钥路径")
            }
            arguments.append(contentsOf: ["-i", keyPath])
            // 只用指定私钥，避免 ssh-agent 里其它 key 造成的 "too many authentication failures"。
            arguments.append(contentsOf: ["-o", "IdentitiesOnly=yes"])
        case .sshConfigOrAgent:
            // 不传任何 -i，不强加 -F，完全交给 ssh-agent 与 ~/.ssh/config。
            arguments.append(contentsOf: ["-o", "BatchMode=yes"])
        case .password:
            // 密码经 SSH_ASKPASS 应答，BatchMode=yes 会禁止该路径，故不加。
            break
        }

        if options.verbose {
            arguments.append("-v")
        }

        // `--` 之后才写目标，防止 host 以 `-` 开头时被解析成选项。
        arguments.append("--")
        arguments.append(target(ssh: ssh, host: host, usesAlias: usesAlias))

        return SSHCommand(executablePath: options.executablePath, arguments: arguments)
    }

    /// 目标写法：别名模式下由 config 决定用户，因此只写别名本身。
    private static func target(ssh: SSHConfig, host: String, usesAlias: Bool) -> String {
        let user = ssh.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if usesAlias || user.isEmpty {
            return host
        }
        return "\(user)@\(host)"
    }

    /// `-L` 的远端主机位置：IPv6 字面量要加方括号，否则冒号会被当成分隔符。
    private static func bracketedIfIPv6(_ host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }
}
