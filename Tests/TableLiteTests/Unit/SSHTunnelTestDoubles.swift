import Foundation
@testable import TableLite

// MARK: - 进程替身

/// 脚本化的一次 ssh 子进程行为。
struct FakeProcessScript: Sendable {
    /// 进程写入 stderr 的内容。
    var stderr: Data = Data()
    /// 启动后立即产生的退出状态；`nil` 表示一直活着。
    var exitStatus: Int32?
    /// 收到 SIGTERM 后是否自行退出。
    var exitsOnTerminate: Bool = true
}

/// 脚本化的进程句柄，记录 terminate / forceKill 调用次数。
actor FakeSSHProcessHandle: SSHProcessHandle {
    private let identifier: Int32
    private let stderrTail: Data
    private var status: Int32?
    private let exitsOnTerminate: Bool

    private(set) var terminateCallCount = 0
    private(set) var forceKillCallCount = 0

    init(identifier: Int32, script: FakeProcessScript) {
        self.identifier = identifier
        self.stderrTail = script.stderr
        self.status = script.exitStatus
        self.exitsOnTerminate = script.exitsOnTerminate
    }

    var processIdentifier: Int32 { identifier }

    func isRunning() -> Bool { status == nil }

    func takeStderr() -> Data { stderrTail }

    func pollExitStatus() -> Int32? { status }

    func terminate() {
        terminateCallCount += 1
        if exitsOnTerminate { status = 0 }
    }

    func forceKill() {
        forceKillCallCount += 1
        status = -9
    }

    /// 测试用：模拟进程自然退出。
    func simulateExit(status: Int32 = 255) {
        self.status = status
    }
}

/// 脚本化的进程启动器：每次 launch 依次取一个脚本，并记录命令与环境变量。
actor FakeSSHProcessRunner: SSHProcessRunning {
    private var scripts: [FakeProcessScript]
    private var nextIdentifier: Int32 = 4200

    private(set) var commands: [SSHCommand] = []
    private(set) var environments: [[String: String]] = []
    private(set) var handles: [FakeSSHProcessHandle] = []

    init(scripts: [FakeProcessScript] = [FakeProcessScript()]) {
        self.scripts = scripts
    }

    func launch(_ command: SSHCommand, environment: [String: String]) async throws -> SSHProcessHandle {
        commands.append(command)
        environments.append(environment)
        let script = scripts.isEmpty ? FakeProcessScript() : scripts.removeFirst()
        nextIdentifier += 1
        let handle = FakeSSHProcessHandle(identifier: nextIdentifier, script: script)
        handles.append(handle)
        return handle
    }
}

// MARK: - 端口替身

/// 脚本化的端口分配与探测。
actor FakeLocalPortProvider: LocalPortProviding {
    private var ports: [UInt16]
    private var connectResponses: [Bool]
    private var fallbackConnect: Bool

    private(set) var allocateCallCount = 0
    private(set) var connectCallCount = 0
    private(set) var probedPorts: [UInt16] = []

    init(
        ports: [UInt16] = [53142],
        connectResponses: [Bool] = [],
        fallbackConnect: Bool = true
    ) {
        self.ports = ports
        self.connectResponses = connectResponses
        self.fallbackConnect = fallbackConnect
    }

    func allocateLocalPort() async throws -> UInt16 {
        allocateCallCount += 1
        if ports.isEmpty {
            return UInt16(clamping: 40000 + allocateCallCount)
        }
        return ports.removeFirst()
    }

    func canConnect(toLocalPort port: UInt16) async -> Bool {
        connectCallCount += 1
        probedPorts.append(port)
        if connectResponses.isEmpty { return fallbackConnect }
        return connectResponses.removeFirst()
    }

    func setFallbackConnect(_ value: Bool) {
        fallbackConnect = value
    }
}

// MARK: - 依赖拼装

/// 用替身拼一份测试依赖；askpass 不落盘。
func makeTestDependencies(
    runner: FakeSSHProcessRunner,
    portProvider: FakeLocalPortProvider
) -> SSHTunnelDependencies {
    SSHTunnelDependencies(
        processRunner: runner,
        portProvider: portProvider,
        sleep: { _ in },
        makeAskpass: { secret in
            SSHAskpassScript(
                directoryURL: URL(fileURLWithPath: "/tmp/tablelite-test-askpass-\(UUID().uuidString)"),
                scriptURL: URL(fileURLWithPath: "/dev/null"),
                environment: SSHAskpassScript.makeEnvironment(secret: secret, scriptPath: "/dev/null")
            )
        }
    )
}

/// 测试用的标准 SSH 配置。
func makeSSHConfig(
    host: String = "bastion.example.com",
    port: Int = 22,
    user: String = "deploy",
    authMethod: SSHAuthMethod = .password,
    privateKeyPath: String? = nil,
    useSSHConfigAlias: Bool = false,
    jumpHost: String? = nil
) -> SSHConfig {
    SSHConfig(
        enabled: true,
        host: host,
        port: port,
        user: user,
        authMethod: authMethod,
        privateKeyPath: privateKeyPath,
        useSSHConfigAlias: useSSHConfigAlias,
        jumpHost: jumpHost
    )
}
