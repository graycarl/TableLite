import Foundation
import XCTest
@testable import TableLite

/// SSHTunnel 状态机：懒启动、就绪轮询、端口重试、健康检查、停止清理。
///
/// 全部通过 T12 注入点用替身驱动，不启动真实 ssh 进程。
/// 见 `docs/tech-designs/04-ssh-tunnel.md` §4、§6、§7。
final class SSHTunnelTests: XCTestCase {

    // MARK: - 工具

    private struct Harness {
        let tunnel: SSHTunnel
        let runner: FakeSSHProcessRunner
        let ports: FakeLocalPortProvider
    }

    private func makeHarness(
        ssh: SSHConfig = makeSSHConfig(authMethod: .sshConfigOrAgent),
        secret: SSHSecret? = nil,
        scripts: [FakeProcessScript] = [FakeProcessScript()],
        ports: [UInt16] = [53142],
        connectResponses: [Bool] = [],
        fallbackConnect: Bool = true
    ) -> Harness {
        let runner = FakeSSHProcessRunner(scripts: scripts)
        let provider = FakeLocalPortProvider(
            ports: ports,
            connectResponses: connectResponses,
            fallbackConnect: fallbackConnect
        )
        let configuration = SSHTunnelConfiguration(
            ssh: ssh,
            remoteHost: "10.0.2.5",
            remotePort: 3306,
            secret: secret
        )
        let tunnel = SSHTunnel(
            configuration: configuration,
            dependencies: makeTestDependencies(runner: runner, portProvider: provider)
        )
        return Harness(tunnel: tunnel, runner: runner, ports: provider)
    }

    // MARK: - 建立

    func testStartEstablishesTunnel() async throws {
        let harness = makeHarness()
        let endpoint = try await harness.tunnel.start()

        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.port, 53142)

        let state = await harness.tunnel.state
        XCTAssertEqual(state, .established(localPort: 53142))

        let commands = await harness.runner.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].arguments.contains("127.0.0.1:53142:10.0.2.5:3306"))

        let allocateCount = await harness.ports.allocateCallCount
        XCTAssertEqual(allocateCount, 1)
    }

    func testStartIsIdempotentWhenEstablished() async throws {
        let harness = makeHarness()
        let first = try await harness.tunnel.start()
        let second = try await harness.tunnel.start()

        XCTAssertEqual(first, second)
        let commands = await harness.runner.commands
        XCTAssertEqual(commands.count, 1, "已建立时不应重复启动 ssh")
    }

    // MARK: - 失败分类

    func testStartClassifiesAuthenticationFailure() async throws {
        let harness = makeHarness(
            ssh: makeSSHConfig(authMethod: .password),
            secret: .password("wrong"),
            scripts: [FakeProcessScript(
                stderr: Data("deploy@bastion: Permission denied (password).\n".utf8),
                exitStatus: 255
            )]
        )

        do {
            _ = try await harness.tunnel.start()
            XCTFail("认证失败必须抛出")
        } catch let error as SSHTunnelError {
            guard case .authenticationFailed(let tail) = error else {
                return XCTFail("应为 authenticationFailed，实际：\(error)")
            }
            XCTAssertTrue(tail.contains("Permission denied"))
        }

        let state = await harness.tunnel.state
        XCTAssertNotNil(state.error)
    }

    func testHostKeyChangeIsDistinctAndNeverEstablished() async throws {
        let banner = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key verification failed.
        """
        let harness = makeHarness(scripts: [FakeProcessScript(
            stderr: Data(banner.utf8),
            exitStatus: 255
        )])

        do {
            _ = try await harness.tunnel.start()
            XCTFail("指纹变化必须失败，不能静默接受")
        } catch let error as SSHTunnelError {
            XCTAssertTrue(error.isHostKeyChanged, "指纹变化必须可区分，实际：\(error)")
            XCTAssertTrue(error.stderrTail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
        }

        let state = await harness.tunnel.state
        XCTAssertNil(state.localPort)
        XCTAssertEqual(state.error?.isHostKeyChanged, true)
    }

    // MARK: - 端口重试

    func testStartRetriesLocalPortInUse() async throws {
        let harness = makeHarness(
            scripts: [
                FakeProcessScript(
                    stderr: Data("bind [127.0.0.1]:50001: Address already in use\n".utf8),
                    exitStatus: 255
                ),
                FakeProcessScript(),
            ],
            ports: [50001, 50002]
        )

        let endpoint = try await harness.tunnel.start()
        XCTAssertEqual(endpoint.port, 50002)

        let commands = await harness.runner.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[0].arguments.contains("127.0.0.1:50001:10.0.2.5:3306"))
        XCTAssertTrue(commands[1].arguments.contains("127.0.0.1:50002:10.0.2.5:3306"))

        let allocateCount = await harness.ports.allocateCallCount
        XCTAssertEqual(allocateCount, 2)
    }

    func testStartGivesUpAfterRetryLimit() async throws {
        let collision = FakeProcessScript(
            stderr: Data("bind [127.0.0.1]:1: Address already in use\n".utf8),
            exitStatus: 255
        )
        let harness = makeHarness(
            scripts: [collision, collision, collision, collision],
            ports: [50001, 50002, 50003, 50004]
        )

        do {
            _ = try await harness.tunnel.start()
            XCTFail("三次都端口冲突时应放弃")
        } catch let error as SSHTunnelError {
            XCTAssertTrue(error.isRetryableLocalPort)
        }

        let allocateCount = await harness.ports.allocateCallCount
        XCTAssertEqual(allocateCount, SSHTunnel.localPortRetryLimit)
    }

    // MARK: - 超时

    func testStartupTimeoutWhenPortNeverOpens() async throws {
        let harness = makeHarness(scripts: [FakeProcessScript()], fallbackConnect: false)

        do {
            _ = try await harness.tunnel.start()
            XCTFail("端口一直不可连应超时")
        } catch let error as SSHTunnelError {
            guard case .startupTimedOut = error else {
                return XCTFail("应为 startupTimedOut，实际：\(error)")
            }
        }

        let probes = await harness.ports.connectCallCount
        XCTAssertEqual(probes, SSHTunnel.maxReadinessAttempts)
    }

    // MARK: - 停止

    func testStopTerminatesProcessAndCloses() async throws {
        let harness = makeHarness(scripts: [FakeProcessScript(exitsOnTerminate: true)])
        _ = try await harness.tunnel.start()

        await harness.tunnel.stop()

        let state = await harness.tunnel.state
        XCTAssertEqual(state, .closed)

        let handles = await harness.runner.handles
        let terminateCount = await handles[0].terminateCallCount
        let killCount = await handles[0].forceKillCallCount
        XCTAssertEqual(terminateCount, 1)
        XCTAssertEqual(killCount, 0, "进程正常退出就不该 SIGKILL")
    }

    func testStopForceKillsUnresponsiveProcess() async throws {
        let harness = makeHarness(scripts: [FakeProcessScript(exitsOnTerminate: false)])
        _ = try await harness.tunnel.start()

        await harness.tunnel.stop()

        let handles = await harness.runner.handles
        let terminateCount = await handles[0].terminateCallCount
        let killCount = await handles[0].forceKillCallCount
        XCTAssertEqual(terminateCount, 1)
        XCTAssertEqual(killCount, 1, "2s 内没退出必须 SIGKILL")
    }

    func testStopIsIdempotent() async throws {
        let harness = makeHarness()
        _ = try await harness.tunnel.start()
        await harness.tunnel.stop()
        await harness.tunnel.stop()

        let state = await harness.tunnel.state
        XCTAssertEqual(state, .closed)
        let handles = await harness.runner.handles
        let terminateCount = await handles[0].terminateCallCount
        XCTAssertEqual(terminateCount, 1)
    }

    func testStopAndWaitProvidesSynchronousSemantics() async throws {
        let harness = makeHarness()
        _ = try await harness.tunnel.start()

        // 供 applicationShouldTerminate 使用：不带 await 的同步调用。
        harness.tunnel.stopAndWait(timeout: .seconds(2))

        let state = await harness.tunnel.state
        XCTAssertEqual(state, .closed)
    }

    // MARK: - 密码认证

    func testPasswordAuthPassesAskpassEnvironment() async throws {
        let harness = makeHarness(
            ssh: makeSSHConfig(authMethod: .password),
            secret: .password("s3cret")
        )

        _ = try await harness.tunnel.start()

        let environments = await harness.runner.environments
        XCTAssertEqual(environments.count, 1)
        XCTAssertEqual(environments[0]["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environments[0][SSHAskpassScript.secretEnvironmentKey], "s3cret")
        XCTAssertNotNil(environments[0]["SSH_ASKPASS"])

        // 密码绝不能出现在命令行参数里。
        let commands = await harness.runner.commands
        XCTAssertFalse(commands[0].commandLine.contains("s3cret"))
    }

    func testPasswordAuthWithoutSecretFailsBeforeLaunching() async throws {
        let harness = makeHarness(ssh: makeSSHConfig(authMethod: .password), secret: nil)

        do {
            _ = try await harness.tunnel.start()
            XCTFail("缺密码应直接失败")
        } catch let error as SSHTunnelError {
            guard case .invalidConfiguration = error else {
                return XCTFail("应为 invalidConfiguration，实际：\(error)")
            }
        }

        let commands = await harness.runner.commands
        XCTAssertTrue(commands.isEmpty, "配置不完整时不应启动 ssh")
    }

    // MARK: - 健康检查

    func testHealthCheckDetectsProcessExit() async throws {
        let harness = makeHarness()
        _ = try await harness.tunnel.start()

        let handles = await harness.runner.handles
        await handles[0].simulateExit(status: 255)

        let healthy = await harness.tunnel.healthCheck()
        XCTAssertFalse(healthy)

        let state = await harness.tunnel.state
        guard case .failed(.tunnelClosed) = state else {
            return XCTFail("应为 failed(.tunnelClosed)，实际：\(state)")
        }
    }

    func testHealthCheckDetectsUnreachablePort() async throws {
        // 第一次探测用于就绪判定（成功），第二次用于健康检查（失败）。
        let harness = makeHarness(connectResponses: [true, false])
        _ = try await harness.tunnel.start()

        let healthy = await harness.tunnel.healthCheck()
        XCTAssertFalse(healthy)

        let state = await harness.tunnel.state
        guard case .failed(.tunnelClosed) = state else {
            return XCTFail("应为 failed(.tunnelClosed)，实际：\(state)")
        }
    }

    func testHealthCheckBeforeStartIsFalse() async throws {
        let harness = makeHarness()
        let healthy = await harness.tunnel.healthCheck()
        XCTAssertFalse(healthy)
    }

    // MARK: - 状态流

    func testStateStreamReplaysCurrentState() async throws {
        let harness = makeHarness()
        let stream = await harness.tunnel.stateStream()
        var iterator = stream.makeAsyncIterator()

        let first = await iterator.next()
        XCTAssertEqual(first, .idle)
    }

    // MARK: - 配置

    func testConfigurationFromConnection() {
        let connection = Connection(
            name: "prod",
            mysql: MySQLConfig(host: "10.0.2.5", port: 3307, user: "app"),
            ssh: makeSSHConfig(host: "bastion")
        )
        let configuration = SSHTunnelConfiguration.make(connection: connection, secret: .passphrase("p"))
        XCTAssertEqual(configuration.remoteHost, "10.0.2.5")
        XCTAssertEqual(configuration.remotePort, 3307)
        XCTAssertEqual(configuration.ssh.host, "bastion")
        XCTAssertEqual(configuration.secret, .passphrase("p"))
    }

    // MARK: - 真实 Process 启动器（不联网）

    func testLiveRunnerRejectsMissingExecutable() async {
        let runner = LiveSSHProcessRunner()
        let command = SSHCommand(executablePath: "/nonexistent/ssh", arguments: ["-V"])
        do {
            _ = try await runner.launch(command, environment: [:])
            XCTFail("不存在的可执行文件必须失败")
        } catch let error as SSHTunnelError {
            guard case .sshExecutableMissing(let path) = error else {
                return XCTFail("应为 sshExecutableMissing，实际：\(error)")
            }
            XCTAssertEqual(path, "/nonexistent/ssh")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
