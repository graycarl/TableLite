import XCTest
@testable import TableLite

/// SSH 命令拼装：三种认证、别名、跳板机、`--` 防注入。
///
/// 见 `docs/tech-designs/04-ssh-tunnel.md` §3、§5，`specs/10-ssh-tunnel.md` §3。
final class SSHCommandBuilderTests: XCTestCase {

    private func build(
        _ ssh: SSHConfig,
        localPort: UInt16 = 53142,
        remoteHost: String = "10.0.2.5",
        remotePort: Int = 3306,
        options: SSHCommandOptions = .default
    ) throws -> SSHCommand {
        try SSHCommandBuilder.build(
            ssh: ssh,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            options: options
        )
    }

    // MARK: 固定部分

    func testBaseArguments() throws {
        let command = try build(makeSSHConfig())
        XCTAssertEqual(command.executablePath, "/usr/bin/ssh")
        XCTAssertTrue(command.arguments.contains("-N"))
        XCTAssertTrue(command.arguments.contains("127.0.0.1:53142:10.0.2.5:3306"))
        XCTAssertTrue(command.arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(command.arguments.contains("ServerAliveInterval=15"))
        XCTAssertTrue(command.arguments.contains("ServerAliveCountMax=3"))
        XCTAssertTrue(command.arguments.contains("ConnectTimeout=15"))
        XCTAssertTrue(command.arguments.contains("StrictHostKeyChecking=accept-new"))
    }

    func testTargetComesAfterDoubleDash() throws {
        let command = try build(makeSSHConfig(host: "bastion.example.com", user: "deploy"))
        XCTAssertEqual(command.arguments.suffix(2).map { $0 }, ["--", "deploy@bastion.example.com"])
    }

    func testHostStartingWithDashIsProtectedByDoubleDash() throws {
        let command = try build(makeSSHConfig(host: "-oProxyCommand=evil", user: "deploy"))
        XCTAssertEqual(command.arguments.suffix(2).map { $0 }, ["--", "deploy@-oProxyCommand=evil"])
    }

    // MARK: 三种认证

    func testPasswordAuthHasNoIdentityAndNoBatchMode() throws {
        let command = try build(makeSSHConfig(authMethod: .password))
        XCTAssertFalse(command.arguments.contains("-i"))
        // BatchMode=yes 会禁止 SSH_ASKPASS 应答，密码认证绝不能加。
        XCTAssertFalse(command.arguments.joined(separator: " ").contains("BatchMode"))
    }

    func testPrivateKeyAuthAddsIdentityAndIdentitiesOnly() throws {
        let command = try build(makeSSHConfig(
            port: 2222,
            authMethod: .privateKey,
            privateKeyPath: "/Users/me/.ssh/id_ed25519"
        ))
        XCTAssertTrue(command.arguments.contains("-i"))
        XCTAssertTrue(command.arguments.contains("/Users/me/.ssh/id_ed25519"))
        XCTAssertTrue(command.arguments.contains("IdentitiesOnly=yes"))
        // 非默认端口才传 -p。
        XCTAssertTrue(command.arguments.contains("-p"))
        XCTAssertTrue(command.arguments.contains("2222"))
    }

    func testSSHConfigOrAgentHasBatchModeAndNoIdentity() throws {
        let command = try build(makeSSHConfig(authMethod: .sshConfigOrAgent))
        XCTAssertFalse(command.arguments.contains("-i"))
        // 不传 -i、不强加 -F；BatchMode 避免无 tty 时挂起。
        XCTAssertFalse(command.arguments.contains("-F"))
        XCTAssertTrue(command.arguments.contains("BatchMode=yes"))
    }

    func testDefaultPortDoesNotAddDashP() throws {
        let command = try build(makeSSHConfig(port: 22, authMethod: .sshConfigOrAgent))
        XCTAssertFalse(command.arguments.contains("-p"))
    }

    // MARK: 别名与跳板机

    func testAliasModeIgnoresPortUserAndKey() throws {
        let ssh = makeSSHConfig(
            host: "prod-db",
            port: 2222,
            user: "deploy",
            authMethod: .privateKey,
            privateKeyPath: "/Users/me/.ssh/id_ed25519",
            useSSHConfigAlias: true
        )
        let command = try build(ssh)
        XCTAssertFalse(command.arguments.contains("-p"))
        XCTAssertFalse(command.arguments.contains("-i"))
        XCTAssertTrue(command.arguments.contains("BatchMode=yes"))
        // 用户由 ~/.ssh/config 决定，目标只写别名。
        XCTAssertEqual(command.arguments.last, "prod-db")
    }

    func testExplicitJumpHostIsPassedThrough() throws {
        let command = try build(makeSSHConfig(authMethod: .sshConfigOrAgent, jumpHost: "user@proxy:22"))
        XCTAssertTrue(command.arguments.contains("-J"))
        XCTAssertTrue(command.arguments.contains("user@proxy:22"))
    }

    func testAliasWithoutJumpHostLeavesProxyJumpToSSHConfig() throws {
        // ProxyJump 写在 ~/.ssh/config 里：命令中不应出现 -J。
        let ssh = makeSSHConfig(
            host: "prod-db",
            authMethod: .sshConfigOrAgent,
            useSSHConfigAlias: true,
            jumpHost: nil
        )
        let command = try build(ssh)
        XCTAssertFalse(command.arguments.contains("-J"))
        XCTAssertEqual(command.arguments.last, "prod-db")
    }

    // MARK: 选项

    func testVerboseAddsDashV() throws {
        let command = try build(makeSSHConfig(), options: SSHCommandOptions(verbose: true))
        XCTAssertTrue(command.arguments.contains("-v"))
    }

    func testCustomExecutablePathAndTimeouts() throws {
        let options = SSHCommandOptions(
            executablePath: "/opt/ssh",
            connectTimeoutSeconds: 5,
            serverAliveIntervalSeconds: 30,
            serverAliveCountMax: 2
        )
        let command = try build(makeSSHConfig(), options: options)
        XCTAssertEqual(command.executablePath, "/opt/ssh")
        XCTAssertTrue(command.arguments.contains("ConnectTimeout=5"))
        XCTAssertTrue(command.arguments.contains("ServerAliveInterval=30"))
        XCTAssertTrue(command.arguments.contains("ServerAliveCountMax=2"))
    }

    func testCommandLineDoesNotLeakSecrets() throws {
        // 口令只走环境变量，参数里不可能出现。
        let command = try build(makeSSHConfig(authMethod: .password))
        XCTAssertFalse(command.commandLine.contains("secret"))
        XCTAssertFalse(command.arguments.contains { $0.contains("Password") && !$0.contains("Prompts") })
    }

    // MARK: 校验

    func testEmptyHostThrows() {
        XCTAssertThrowsError(try build(makeSSHConfig(host: "  "))) { error in
            XCTAssertEqual(error as? SSHTunnelError, .invalidConfiguration(reason: "SSH 主机为空"))
        }
    }

    func testEmptyRemoteHostThrows() {
        XCTAssertThrowsError(try build(makeSSHConfig(), remoteHost: " ")) { error in
            XCTAssertEqual(error as? SSHTunnelError, .invalidConfiguration(reason: "MySQL 主机为空"))
        }
    }

    func testInvalidRemotePortThrows() {
        XCTAssertThrowsError(try build(makeSSHConfig(), remotePort: 0))
        XCTAssertThrowsError(try build(makeSSHConfig(), remotePort: 70000))
    }

    func testPrivateKeyWithoutPathThrows() {
        XCTAssertThrowsError(try build(makeSSHConfig(authMethod: .privateKey, privateKeyPath: "  "))) { error in
            XCTAssertEqual(
                error as? SSHTunnelError,
                .invalidConfiguration(reason: "使用私钥认证时必须指定私钥路径")
            )
        }
    }

    func testZeroLocalPortThrows() {
        XCTAssertThrowsError(try build(makeSSHConfig(), localPort: 0))
    }

    func testInvalidSSHPortThrowsWhenNotAlias() {
        XCTAssertThrowsError(try build(makeSSHConfig(port: 0, authMethod: .sshConfigOrAgent))) { error in
            XCTAssertEqual(error as? SSHTunnelError, .invalidConfiguration(reason: "SSH 端口无效"))
        }
        XCTAssertThrowsError(try build(makeSSHConfig(port: 70000, authMethod: .sshConfigOrAgent)))
    }

    func testInvalidSSHPortIsIgnoredInAliasMode() throws {
        // 别名模式下端口由 ~/.ssh/config 决定，端口字段不参与拼装。
        let command = try build(makeSSHConfig(port: 0, useSSHConfigAlias: true))
        XCTAssertFalse(command.arguments.contains("-p"))
    }

    func testIPv6RemoteHostIsBracketed() throws {
        let command = try build(makeSSHConfig(), remoteHost: "fd00::15")
        XCTAssertTrue(command.arguments.contains("127.0.0.1:53142:[fd00::15]:3306"))
    }

    // MARK: effectiveAuthMethod

    func testAliasForcesConfigOrAgentAuth() {
        let configuration = SSHTunnelConfiguration(
            ssh: makeSSHConfig(authMethod: .privateKey, privateKeyPath: "/k", useSSHConfigAlias: true),
            remoteHost: "10.0.2.5",
            remotePort: 3306
        )
        XCTAssertEqual(configuration.effectiveAuthMethod, .sshConfigOrAgent)
    }
}
