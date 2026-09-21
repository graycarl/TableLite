import Foundation

/// SSH 命令行拼装。**纯函数**：不启动进程、不读写文件系统，便于单元测试。
///
/// 见 docs/tech-designs/04-ssh-tunnel.md §3（命令拼装）、specs/10-ssh-tunnel.md §3（三种认证）。
struct SSHCommandBuilder: Sendable {

    /// 一次拼装的结果。
    ///
    /// `SSHTunnel` 负责把 `askpassScript` 落盘（权限 0700），再把落盘路径写进
    /// `SSH_ASKPASS` 后合并到进程环境里。`environment` 里因此只带与 askpass 有关、
    /// 又不需要文件系统信息的变量。
    struct Plan: Hashable, Sendable {
        /// 例如 `/usr/bin/ssh`。
        var executable: URL
        /// 不含 executable 的参数列表。
        var arguments: [String]
        /// 叠加在父进程环境之上的额外环境变量（ASKPASS 相关）。
        var environment: [String: String]
        /// askpass 脚本内容（**不含密码**）；为 nil 时不需要 askpass。
        var askpassScript: String?
    }

    /// 系统自带 ssh（docs/04 §1）。
    static let executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

    /// 保活间隔（秒）。配合 `ServerAliveCountMax` 判断隧道是否已死。
    static let serverAliveIntervalSeconds = 30
    static let serverAliveCountMax = 3
    static let connectTimeoutSeconds = 10
    static let defaultSSHPort = 22

    /// askpass 脚本读取密码 / 口令的环境变量名。
    ///
    /// 用子进程环境变量传密码，脚本文件本身不含明文（docs/04 §5）。
    static let askpassSecretEnvKey = "MTL_SSH_ASKPASS_SECRET"

    /// 一次性 askpass 脚本内容。
    ///
    /// 密码 / 口令不写在此文件中，由父进程通过 `MTL_SSH_ASKPASS_SECRET` 注入；
    /// 脚本本身无状态，可在多个隧道之间复用（由 `SSHTunnel` 落盘并设置 0700）。
    static let askpassScriptContent = #"""
    #!/bin/sh
    # TableLite 一次性 askpass 脚本（docs/tech-designs/04-ssh-tunnel.md §5）。
    # 密码 / 口令不写在此文件中，由父进程通过环境变量 MTL_SSH_ASKPASS_SECRET 传入。
    printf '%s\n' "$MTL_SSH_ASKPASS_SECRET"
    """#

    /// 拼装一次 `ssh` 调用。
    ///
    /// - Parameters:
    ///   - config: 用户配置。
    ///   - localPort: 本地转发端口（由 `PortAllocator` 分配）。
    ///   - remoteHost / remotePort: 隧道另一端（跳板机能访问到的 MySQL 端点）。
    ///   - password: 从 Keychain 取到的 SSH 密码，可能为 nil。
    ///   - passphrase: 从 Keychain 取到的私钥口令，可能为 nil。
    static func build(config: SSHTunnelConfig,
                      localPort: Int,
                      remoteHost: String,
                      remotePort: Int,
                      password: String?,
                      passphrase: String?) -> Plan {
        // 参数顺序固定，见 docs/04 §3。
        var arguments: [String] = []

        // 1) 固定选项。这几项由 TableLite 覆盖 ~/.ssh/config 里的同名项（specs/10 §3.1）：
        //    转发失败立即退出、keepalive、连接超时、首次连接自动接受主机指纹。
        arguments += ["-o", "ExitOnForwardFailure=yes"]
        arguments += ["-o", "ServerAliveInterval=\(serverAliveIntervalSeconds)"]
        arguments += ["-o", "ServerAliveCountMax=\(serverAliveCountMax)"]
        arguments += ["-o", "ConnectTimeout=\(connectTimeoutSeconds)"]
        arguments += ["-o", "StrictHostKeyChecking=accept-new"]

        // 2) 只做端口转发，不执行远端命令。
        arguments += ["-N"]

        // 3) 本地端口转发：127.0.0.1:<localPort> -> <remoteHost>:<remotePort>。
        arguments += ["-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"]

        // 4) 跳板机（先连 A 再跳 B）。
        let jumpHost = config.jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !jumpHost.isEmpty {
            arguments += ["-J", jumpHost]
        }

        // 5) 端口：默认 22 不传 -p，交给 ssh / ~/.ssh/config 决定。
        if config.port != defaultSSHPort {
            arguments += ["-p", String(config.port)]
        }

        // 6) 只有私钥认证才传 -i + IdentitiesOnly；
        //    config 认证不传任何 -i，也不强加 -F（specs/10 §3.1）。
        if config.authMethod == .privateKey {
            let keyPath = expandedPath(config.privateKeyPath)
            if !keyPath.isEmpty {
                arguments += ["-i", keyPath]
            }
            arguments += ["-o", "IdentitiesOnly=yes"]
        }

        // 7) `--` 之后才是目标，防止 host 被 ssh 解析成选项（docs/04 §3）。
        arguments += ["--"]
        let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = config.user.trimmingCharacters(in: .whitespacesAndNewlines)
        // 使用 ssh config 别名时 user 可以为空，此时只传 host。
        arguments.append(user.isEmpty ? host : "\(user)@\(host)")

        // 8) 认证：密码认证用 password，私钥认证用 passphrase（私钥有口令时）。
        var environment: [String: String] = [:]
        var askpassScript: String?
        if let secret = askpassSecret(config: config, password: password, passphrase: passphrase) {
            // 无 tty 场景下强制走 askpass（docs/04 §5）。
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment[askpassSecretEnvKey] = secret
            askpassScript = askpassScriptContent
        }

        return Plan(executable: executableURL,
                    arguments: arguments,
                    environment: environment,
                    askpassScript: askpassScript)
    }

    /// 按认证方式选出需要交给 askpass 的秘密值。为 nil 表示不需要 askpass。
    private static func askpassSecret(config: SSHTunnelConfig,
                                      password: String?,
                                      passphrase: String?) -> String? {
        switch config.authMethod {
        case .config:
            // 交给 ssh / agent 自己处理，不要注入任何秘密。
            return nil
        case .privateKey:
            guard let passphrase, !passphrase.isEmpty else { return nil }
            return passphrase
        case .password:
            guard let password, !password.isEmpty else { return nil }
            return password
        }
    }

    /// 把 `~` 展开为 home 目录。其余原样返回。
    private static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }
}
