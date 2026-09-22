import Foundation

// MARK: - 端点

/// 隧道建立后 MySQL 应该连接的本机端点。
public struct SSHTunnelEndpoint: Sendable, Equatable {
    /// 只绑回环（`04` §4）。
    public static let localHost = "127.0.0.1"

    public let host: String
    public let port: UInt16

    public init(port: UInt16) {
        self.host = Self.localHost
        self.port = port
    }
}

// MARK: - 口令

/// 上层从 Keychain 取出的 SSH 口令。本层只接收字符串，不碰 Keychain。
public enum SSHSecret: Sendable, Equatable {
    /// SSH 账号密码（`authMethod == .password`）。
    case password(String)
    /// 私钥口令（`authMethod == .privateKey` 且私钥已加密）。
    case passphrase(String)

    public var value: String {
        switch self {
        case .password(let value), .passphrase(let value): return value
        }
    }
}

// MARK: - 配置

/// 建立一条隧道所需的全部信息。
public struct SSHTunnelConfiguration: Sendable, Equatable {
    public var ssh: SSHConfig

    /// MySQL 在远端（跳板机视角）的主机名 / IP。
    public var remoteHost: String
    /// MySQL 远端端口。
    public var remotePort: Int

    /// 密码认证的密码，或私钥认证的口令。由上层从 Keychain 取。
    public var secret: SSHSecret?

    public init(ssh: SSHConfig, remoteHost: String, remotePort: Int, secret: SSHSecret? = nil) {
        self.ssh = ssh
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.secret = secret
    }

    /// 由连接配置构造。直连模式请先判断 `ssh.enabled`（`04` §8）。
    public static func make(connection: Connection, secret: SSHSecret?) -> SSHTunnelConfiguration {
        SSHTunnelConfiguration(
            ssh: connection.ssh,
            remoteHost: connection.mysql.host,
            remotePort: connection.mysql.port,
            secret: secret
        )
    }

    /// 别名模式下认证完全交给 `~/.ssh/config`，分类错误时也按 `sshConfigOrAgent` 处理。
    public var effectiveAuthMethod: SSHAuthMethod {
        ssh.useSSHConfigAlias ? .sshConfigOrAgent : ssh.authMethod
    }
}

// MARK: - 状态

/// 隧道状态机（`docs/tech-designs/04-ssh-tunnel.md` §6）。
public enum SSHTunnelState: Sendable, Equatable {
    case idle
    case starting
    case established(localPort: UInt16)
    /// 启动失败或运行中断开，携带可展示的错误。
    case failed(SSHTunnelError)
    case closed

    public var localPort: UInt16? {
        if case .established(let port) = self { return port }
        return nil
    }

    public var error: SSHTunnelError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// MARK: - 依赖

/// `SSHTunnel` 的外部依赖，方便单测注入（T12）。
///
/// 决策（本模块落地，待登记到 `docs/tech-designs/13-open-questions.md` T12）：
/// 只抽 `ProcessRunner` 与 `PortAllocator` 两件事，外加一个 sleep 钩子。
/// 不引入通用 `Clock`（`15-testing.md` §3 提到的 `Clock` 未来由 AppEnvironment 提供，
/// 这里先用最小的 `sleep` 闭包，等 `Clock` 落地后再替换）。askpass 落盘用闭包注入，
/// 测试里用不写盘的假实现。
public struct SSHTunnelDependencies: Sendable {
    public var processRunner: any SSHProcessRunning
    public var portProvider: any LocalPortProviding
    /// 轮询之间的等待。测试里传 `{ _ in }` 即可瞬时跑完。
    public var sleep: @Sendable (Duration) async throws -> Void
    /// 生成一次性 askpass 脚本。
    public var makeAskpass: @Sendable (String) throws -> SSHAskpassScript

    public init(
        processRunner: any SSHProcessRunning,
        portProvider: any LocalPortProviding,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        makeAskpass: @escaping @Sendable (String) throws -> SSHAskpassScript
    ) {
        self.processRunner = processRunner
        self.portProvider = portProvider
        self.sleep = sleep
        self.makeAskpass = makeAskpass
    }

    public static var live: SSHTunnelDependencies {
        SSHTunnelDependencies(
            processRunner: LiveSSHProcessRunner(),
            portProvider: LiveLocalPortProvider(),
            sleep: { duration in try await Task<Never, Never>.sleep(for: duration) },
            makeAskpass: { secret in try SSHAskpassScript.create(secret: secret) }
        )
    }
}

// MARK: - 隧道

/// SSH 隧道（actor）。
///
/// 懒启动（`04` §6）：只在真正要连数据库时调用 `start()`。
/// `SessionManager` / `ConnectionSession` 的对接方式见本文件底部注释与交付报告。
public actor SSHTunnel {

    // MARK: 常量

    /// 就绪轮询间隔（`04` §6）。
    public static let readinessPollInterval: Duration = .milliseconds(100)
    /// 就绪轮询上限（`04` §6）。
    public static let readinessTimeoutSeconds = 15
    /// 就绪轮询次数 = 15s / 100ms。
    public static let maxReadinessAttempts = 150
    /// 停止时等待 SIGTERM 生效的时长（`04` §6、`05` §7）。
    public static let terminationGracePeriodSeconds = 2
    /// SIGTERM 后的轮询间隔。
    public static let terminationPollInterval: Duration = .milliseconds(100)
    /// SIGTERM 后最多轮询次数 = 2s / 100ms。
    public static let maxTerminationPollAttempts = 20
    /// 本地端口被占用时的重试上限（`04` §4）。
    public static let localPortRetryLimit = 3

    // MARK: 属性

    public nonisolated let configuration: SSHTunnelConfiguration
    private let dependencies: SSHTunnelDependencies

    private var currentState: SSHTunnelState = .idle
    private var process: SSHProcessHandle?
    private var askpass: SSHAskpassScript?
    private var stopRequested = false
    private var continuations: [UUID: AsyncStream<SSHTunnelState>.Continuation] = [:]

    public init(configuration: SSHTunnelConfiguration, dependencies: SSHTunnelDependencies = .live) {
        self.configuration = configuration
        self.dependencies = dependencies
    }

    // MARK: 状态

    public var state: SSHTunnelState { currentState }

    /// 订阅状态变化（先回放当前状态）。UI 状态一律在 `@MainActor` 侧消费。
    public func stateStream() -> AsyncStream<SSHTunnelState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SSHTunnelState>.makeStream()
        continuations[id] = continuation
        continuation.yield(currentState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    /// 最后一次捕获到的 stderr 尾部（排查用）。
    public func capturedStderr() async -> String {
        guard let process else { return "" }
        return String(decoding: await process.takeStderr(), as: UTF8.self)
    }

    // MARK: 启动

    /// 建立隧道并返回本机端点。
    ///
    /// 幂等：已建立且进程仍存活时直接返回原端口。
    @discardableResult
    public func start() async throws -> SSHTunnelEndpoint {
        if case .established(let port) = currentState, let process, await process.isRunning() {
            return SSHTunnelEndpoint(port: port)
        }
        if case .starting = currentState {
            throw SSHTunnelError.invalidConfiguration(reason: "SSH 隧道正在启动")
        }

        // 清掉上一次失败可能留下的进程与 askpass。
        await cleanupProcess()
        stopRequested = false

        if configuration.effectiveAuthMethod == .password, configuration.secret == nil {
            let error = SSHTunnelError.invalidConfiguration(reason: "使用密码认证时必须提供密码")
            setState(.failed(error))
            throw error
        }

        setState(.starting)

        var lastPortInUse: SSHTunnelError?
        for attempt in 1...Self.localPortRetryLimit {
            if stopRequested {
                let error = SSHTunnelError.tunnelClosed(stderrTail: "")
                setState(.closed)
                throw error
            }

            let port: UInt16
            do {
                port = try await dependencies.portProvider.allocateLocalPort()
            } catch let error as SSHTunnelError {
                setState(.failed(error))
                throw error
            } catch {
                let wrapped = SSHTunnelError.portAllocationFailed(reason: String(describing: error))
                setState(.failed(wrapped))
                throw wrapped
            }

            let command: SSHCommand
            do {
                command = try SSHCommandBuilder.build(
                    ssh: configuration.ssh,
                    localPort: port,
                    remoteHost: configuration.remoteHost,
                    remotePort: configuration.remotePort
                )
            } catch let error as SSHTunnelError {
                setState(.failed(error))
                throw error
            }

            let environment: [String: String]
            do {
                (askpass, environment) = try prepareAskpass()
            } catch let error as SSHTunnelError {
                setState(.failed(error))
                throw error
            } catch {
                let wrapped = SSHTunnelError.processLaunchFailed(reason: String(describing: error))
                setState(.failed(wrapped))
                throw wrapped
            }

            let handle: SSHProcessHandle
            do {
                handle = try await dependencies.processRunner.launch(command, environment: environment)
            } catch let error as SSHTunnelError {
                setState(.failed(error))
                throw error
            } catch {
                let wrapped = SSHTunnelError.processLaunchFailed(reason: String(describing: error))
                setState(.failed(wrapped))
                throw wrapped
            }

            process = handle

            switch await waitUntilReady(handle: handle, port: port) {
            case .ready:
                setState(.established(localPort: port))
                return SSHTunnelEndpoint(port: port)

            case .failed(let error):
                let stderrTail = String(decoding: await handle.takeStderr(), as: UTF8.self)
                await cleanupProcess()
                if error.isRetryableLocalPort, attempt < Self.localPortRetryLimit {
                    lastPortInUse = error
                    continue
                }
                let finalError = error.stderrTail.isEmpty ? enrich(error, with: stderrTail) : error
                setState(.failed(finalError))
                throw finalError
            }
        }

        let error = lastPortInUse ?? SSHTunnelError.startupTimedOut(stderrTail: "")
        setState(.failed(error))
        throw error
    }

    // MARK: 健康检查

    /// 周期探测：进程是否还活着、本地端口是否还能 connect（`04` §6）。
    /// 任一失败都把状态置为 `failed(.tunnelClosed)` 并返回 false。
    public func healthCheck() async -> Bool {
        guard case .established(let port) = currentState, let process else {
            return false
        }
        if await process.pollExitStatus() != nil {
            let stderr = String(decoding: await process.takeStderr(), as: UTF8.self)
            setState(.failed(.tunnelClosed(stderrTail: stderr)))
            return false
        }
        if await dependencies.portProvider.canConnect(toLocalPort: port) {
            return true
        }
        let stderr = String(decoding: await process.takeStderr(), as: UTF8.self)
        setState(.failed(.tunnelClosed(stderrTail: stderr)))
        return false
    }

    // MARK: 停止

    /// 停止隧道：`terminate()` → 等待 2s → 仍存活则 `SIGKILL`；删除 askpass；状态置 `closed`。
    ///
    /// 幂等。
    public func stop() async {
        stopRequested = true
        await cleanupProcess()
        setState(.closed)
    }

    /// 退出清理用的**同步等待**版本（`05` §7 的 `applicationShouldTerminate`）。
    ///
    /// 内部把 `stop()` 放到 detached task（不动 MainActor），当前线程阻塞等待；
    /// 超时只是不再等，`stop()` 自己的 2s + SIGKILL 仍会执行完。
    public nonisolated func stopAndWait(timeout: Duration = .seconds(3)) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await self.stop()
            semaphore.signal()
        }
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        _ = semaphore.wait(timeout: .now() + seconds)
    }

    // MARK: - 私有

    private enum ReadinessOutcome {
        case ready
        case failed(SSHTunnelError)
    }

    private func prepareAskpass() throws -> (SSHAskpassScript?, [String: String]) {
        guard let secret = configuration.secret else {
            return (nil, [:])
        }
        let script = try dependencies.makeAskpass(secret.value)
        return (script, script.environment)
    }

    /// 就绪判定不用固定 sleep：轮询本地端口，间隔 100ms、上限 15s；
    /// 期间 ssh 退出则立即失败并带上 stderr（`04` §6）。
    private func waitUntilReady(handle: SSHProcessHandle, port: UInt16) async -> ReadinessOutcome {
        for _ in 0..<Self.maxReadinessAttempts {
            if stopRequested {
                await handle.forceKill()
                return .failed(SSHTunnelError.tunnelClosed(stderrTail: ""))
            }

            if let status = await handle.pollExitStatus() {
                let stderrTail = String(decoding: await handle.takeStderr(), as: UTF8.self)
                return .failed(SSHStderrClassifier.classify(
                    stderrTail: stderrTail,
                    exitStatus: status,
                    authMethod: configuration.effectiveAuthMethod
                ))
            }

            if await dependencies.portProvider.canConnect(toLocalPort: port) {
                return .ready
            }

            do {
                try await dependencies.sleep(Self.readinessPollInterval)
            } catch {
                // 外层取消：直接收敛，不要留进程。
                await handle.forceKill()
                return .failed(SSHTunnelError.tunnelClosed(stderrTail: ""))
            }
        }

        let stderrTail = String(decoding: await handle.takeStderr(), as: UTF8.self)
        return .failed(SSHTunnelError.startupTimedOut(stderrTail: stderrTail))
    }

    /// 清理进程与 askpass。调用方负责置状态。
    private func cleanupProcess() async {
        askpass?.remove()
        askpass = nil

        guard let handle = process else { return }
        process = nil

        guard await handle.isRunning() else { return }
        await handle.terminate()
        if !(await waitForExit(handle, attempts: Self.maxTerminationPollAttempts)) {
            await handle.forceKill()
            _ = await waitForExit(handle, attempts: 5)
        }
    }

    private func waitForExit(_ handle: SSHProcessHandle, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if await handle.pollExitStatus() != nil { return true }
            do {
                try await dependencies.sleep(Self.terminationPollInterval)
            } catch {
                return false
            }
        }
        return await handle.pollExitStatus() != nil
    }

    /// 分类器没拿到 stderr 时，用调用点补上的 stderr 再补一次。
    private func enrich(_ error: SSHTunnelError, with stderrTail: String) -> SSHTunnelError {
        guard !stderrTail.isEmpty else { return error }
        switch error {
        case .startupTimedOut: return .startupTimedOut(stderrTail: stderrTail)
        case .connectionFailed: return .connectionFailed(stderrTail: stderrTail)
        case .authenticationFailed: return .authenticationFailed(stderrTail: stderrTail)
        case .privateKeyRejected: return .privateKeyRejected(stderrTail: stderrTail)
        case .hostKeyChanged: return .hostKeyChanged(stderrTail: stderrTail)
        case .tunnelClosed: return .tunnelClosed(stderrTail: stderrTail)
        default: return error
        }
    }

    private func setState(_ newState: SSHTunnelState) {
        currentState = newState
        for continuation in continuations.values {
            continuation.yield(newState)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
