import Darwin
import XCTest
@testable import TableLite

/// `SSHCommandBuilder` 的纯函数单测。
/// 覆盖 docs/tech-designs/04-ssh-tunnel.md §3–§5 与 specs/10-ssh-tunnel.md §3 的硬约束。
final class SSHCommandBuilderTests: XCTestCase {

    // MARK: - 构造辅助

    private func makeConfig(auth: SSHAuthMethod = .config,
                            host: String = "bastion.example.com",
                            port: Int = 22,
                            user: String = "alice",
                            privateKeyPath: String = "",
                            useSSHConfigAlias: Bool = false,
                            jumpHost: String = "") -> SSHTunnelConfig {
        var config = SSHTunnelConfig()
        config.enabled = true
        config.host = host
        config.port = port
        config.user = user
        config.authMethod = auth
        config.privateKeyPath = privateKeyPath
        config.useSSHConfigAlias = useSSHConfigAlias
        config.jumpHost = jumpHost
        return config
    }

    private func build(_ config: SSHTunnelConfig,
                       localPort: Int = 12345,
                       remoteHost: String = "10.0.2.5",
                       remotePort: Int = 3306,
                       password: String? = nil,
                       passphrase: String? = nil) -> SSHCommandBuilder.Plan {
        SSHCommandBuilder.build(config: config,
                                localPort: localPort,
                                remoteHost: remoteHost,
                                remotePort: remotePort,
                                password: password,
                                passphrase: passphrase)
    }

    /// 断言参数里存在 `flag value` 这一对（相邻）。
    private func assertPair(_ plan: SSHCommandBuilder.Plan,
                            _ flag: String,
                            _ value: String,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
        var found = false
        for index in plan.arguments.indices where plan.arguments[index] == flag {
            if plan.arguments.indices.contains(index + 1), plan.arguments[index + 1] == value {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "参数里应包含 `\(flag) \(value)`，实际：\(plan.arguments)", file: file, line: line)
    }

    private func assertNoFlag(_ plan: SSHCommandBuilder.Plan,
                              _ flag: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertFalse(plan.arguments.contains(flag), "参数里不应包含 `\(flag)`，实际：\(plan.arguments)", file: file, line: line)
    }

    // MARK: - 固定选项与 -L

    func testFixedOptionsAndLocalForwardAreAlwaysPresent() {
        let plan = build(makeConfig())

        XCTAssertEqual(plan.executable.path, "/usr/bin/ssh")
        assertPair(plan, "-o", "ExitOnForwardFailure=yes")
        assertPair(plan, "-o", "ServerAliveInterval=30")
        assertPair(plan, "-o", "ServerAliveCountMax=3")
        assertPair(plan, "-o", "ConnectTimeout=10")
        assertPair(plan, "-o", "StrictHostKeyChecking=accept-new")
        XCTAssertTrue(plan.arguments.contains("-N"), "-N 表示不执行远端命令")
        assertPair(plan, "-L", "127.0.0.1:12345:10.0.2.5:3306")
        // 不使用 shell：executable 是 ssh 本身，参数逐项传递。
        XCTAssertEqual(plan.executable.lastPathComponent, "ssh")
    }

    // MARK: - config 认证

    func testConfigAuthHasNoIdentityAndNoForcedConfigFile() {
        let plan = build(makeConfig(auth: .config))

        // 完全不传任何 -i，不强加 -F，也不加 IdentitiesOnly（specs/10 §3.1）。
        assertNoFlag(plan, "-i")
        assertNoFlag(plan, "-F")
        XCTAssertFalse(plan.arguments.contains("IdentitiesOnly=yes"))
        // 但隧道必需的固定项与 -L 仍然在。
        assertPair(plan, "-o", "ExitOnForwardFailure=yes")
        assertPair(plan, "-L", "127.0.0.1:12345:10.0.2.5:3306")
    }

    // MARK: - 私钥认证

    func testPrivateKeyAuthPassesIdentityAndIdentitiesOnly() {
        let plan = build(makeConfig(auth: .privateKey,
                                    privateKeyPath: "/Users/me/.ssh/id_ed25519"))

        assertPair(plan, "-i", "/Users/me/.ssh/id_ed25519")
        assertPair(plan, "-o", "IdentitiesOnly=yes")
    }

    // MARK: - 密码认证

    func testPasswordAuthUsesAskpassAndScriptHasNoPlaintext() {
        let secret = "s3cr3t-p@ssw0rd"
        let plan = build(makeConfig(auth: .password), password: secret)

        XCTAssertEqual(plan.environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(plan.environment[SSHCommandBuilder.askpassSecretEnvKey], secret)

        let script = try? XCTUnwrap(plan.askpassScript)
        XCTAssertNotNil(script)
        XCTAssertFalse(script?.contains(secret) ?? true, "askpass 脚本里不能出现明文密码")
        XCTAssertTrue(script?.contains(SSHCommandBuilder.askpassSecretEnvKey) ?? false,
                      "脚本应从环境变量读取密码")
    }

    func testPasswordAuthWithoutPasswordDoesNotUseAskpass() {
        let plan = build(makeConfig(auth: .password), password: nil)

        XCTAssertNil(plan.askpassScript)
        XCTAssertNil(plan.environment["SSH_ASKPASS_REQUIRE"])
    }

    func testPrivateKeyPassphraseUsesAskpass() {
        let passphrase = "key-passphrase"
        let plan = build(makeConfig(auth: .privateKey, privateKeyPath: "/Users/me/.ssh/id_rsa"),
                         passphrase: passphrase)

        XCTAssertEqual(plan.environment[SSHCommandBuilder.askpassSecretEnvKey], passphrase)
        XCTAssertEqual(plan.environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertFalse(plan.askpassScript?.contains(passphrase) ?? true)
    }

    func testConfigAuthNeverUsesAskpassEvenWithSecrets() {
        let plan = build(makeConfig(auth: .config), password: "x", passphrase: "y")

        XCTAssertNil(plan.askpassScript)
        XCTAssertTrue(plan.environment.isEmpty)
    }

    // MARK: - 端口

    func testDefaultPortDoesNotPassDashP() {
        let plan = build(makeConfig(port: 22))
        assertNoFlag(plan, "-p")
    }

    func testNonDefaultPortPassesDashP() {
        let plan = build(makeConfig(port: 2222))
        assertPair(plan, "-p", "2222")
    }

    // MARK: - 跳板机

    func testJumpHostPassesDashJ() {
        let plan = build(makeConfig(jumpHost: "user@proxy:22"))
        assertPair(plan, "-J", "user@proxy:22")
    }

    func testEmptyJumpHostDoesNotPassDashJ() {
        let plan = build(makeConfig(jumpHost: "   "))
        assertNoFlag(plan, "-J")
    }

    // MARK: - 目标写法与 -- 分隔

    func testTargetAfterDoubleDashAndUserPrefix() {
        let plan = build(makeConfig(host: "bastion.example.com", user: "alice"))

        let separator = plan.arguments.firstIndex(of: "--")
        XCTAssertNotNil(separator, "-- 必须出现，防止 host 被当成选项")
        XCTAssertEqual(plan.arguments.last, "alice@bastion.example.com")
        if let separator {
            XCTAssertEqual(separator, plan.arguments.count - 2, "-- 应紧邻目标")
        }
    }

    func testAliasWithEmptyUserTargetsHostOnly() {
        let plan = build(makeConfig(host: "my-alias", user: "",
                                    useSSHConfigAlias: true))

        XCTAssertEqual(plan.arguments.last, "my-alias")
        assertNoFlag(plan, "-p")
        assertNoFlag(plan, "-i")
    }

    // MARK: - 参数顺序确定

    func testBuildIsDeterministicForSameInput() {
        let config = makeConfig(auth: .privateKey,
                                host: "bastion.example.com",
                                port: 2222,
                                user: "alice",
                                privateKeyPath: "/Users/me/.ssh/id_ed25519",
                                jumpHost: "user@proxy:22")

        let first = build(config, password: "p", passphrase: "q")
        let second = build(config, password: "p", passphrase: "q")

        XCTAssertEqual(first, second, "纯函数对同一输入必须给出相同参数顺序与内容")
        XCTAssertEqual(first.arguments, second.arguments)
    }

    func testDoubleDashIsBeforeTargetAndAfterOptions() {
        let plan = build(makeConfig(auth: .privateKey, port: 2200, privateKeyPath: "/k"))

        guard let separator = plan.arguments.firstIndex(of: "--") else {
            return XCTFail("缺少 --")
        }
        // 所有 -o / -L / -i / -p / -J 之类的选项都在 -- 之前。
        for flag in ["-o", "-L", "-i", "-p", "-J", "-N"] where plan.arguments.contains(flag) {
            let index = plan.arguments.firstIndex(of: flag)!
            XCTAssertLessThan(index, separator, "\(flag) 应在 -- 之前")
        }
    }
}

/// 端口分配的基本行为。真正的窗口期重试在 `SSHTunnel` 里。
final class PortAllocatorTests: XCTestCase {

    func testAllocateReturnsUsableNonPrivilegedPort() throws {
        let port = try PortAllocator.allocateLocalPort()
        XCTAssertGreaterThan(port, 0)
        XCTAssertLessThanOrEqual(port, 65535)
    }

    /// 分配完成后 socket 已关闭，因此拿到的端口应当还能被重新 bind。
    func testAllocatedPortIsActuallyFree() throws {
        let port = try PortAllocator.allocateLocalPort()
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(result, 0, "分配后应立即释放，端口应可再次 bind")
    }
}
