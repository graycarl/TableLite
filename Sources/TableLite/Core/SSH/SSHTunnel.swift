import Darwin
import Foundation

/// SSH 隧道：调 `/usr/bin/ssh -L` 把远端 MySQL 端口映射到本地临时端口。
///
/// 之后 `MySQLSession` 只连 `127.0.0.1:<临时端口>`，数据访问层完全不需要知道 SSH 的存在。
/// 见 docs/tech-designs/04-ssh-tunnel.md（方案 / 端口分配 / 认证 / 生命周期 / 连接流程）、
/// specs/10-ssh-tunnel.md（用户可见行为与错误文案）。
actor SSHTunnel {

    enum State: Sendable, Equatable {
        case idle
        case starting
        case ready(port: Int)
        case failed(reason: String)
        case stopped
    }

    // MARK: - 依赖

    private let config: SSHTunnelConfig
    private let remoteHost: String
    private let remotePort: Int
    private let password: String?
    private let passphrase: String?
    private let clock: any Clock
    private let runner: any ProcessRunning
    private let fileSystem: any FileSystemLocator

    // MARK: - 运行时状态

    private(set) var state: State = .idle
    private(set) var lastError: MySQLError?

    /// 隧道 stderr 尾部（错误面板「查看详细输出」用）。
    private var stderrTail = ""
    var errorOutput: String { stderrTail }

    private var process: (any RunningProcess)?
    private var askpassURL: URL?
    private var processExited = false
    private var isStopping = false

    // MARK: - 常量（docs/04 §4、§6）

    private static let pollInterval: TimeInterval = 0.1
    private static let readyTimeout: TimeInterval = 15
    private static let gracefulStopTimeout: TimeInterval = 2
    private static let maxAttempts = 3
    private static let stderrTailLimit = 8192

    init(config: SSHTunnelConfig,
         remoteHost: String,
         remotePort: Int,
         password: String?,
         passphrase: String?,
         clock: any Clock,
         runner: any ProcessRunning = LiveProcessRunner(),
         fileSystem: any FileSystemLocator) {
        self.config = config
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.password = password
        self.passphrase = passphrase
        self.clock = clock
        self.runner = runner
        self.fileSystem = fileSystem
    }

    // MARK: - 启动

    /// 建隧道并轮询本地端口就绪（100ms 一次，上限 15s；期间进程退出立即失败）。
    /// 返回本地端口。端口被占用时换端口重试，最多 3 次。
    @discardableResult
    func start() async throws -> Int {
        if case .ready(let port) = state { return port }

        state = .starting
        lastError = nil
        stderrTail = ""
        isStopping = false

        var fatal: MySQLError?
        for _ in 1...Self.maxAttempts {
            do {
                let port = try PortAllocator.allocateLocalPort()
                if let readyPort = try await launchAndWait(port: port) {
                    state = .ready(port: readyPort)
                    return readyPort
                }
                // launchAndWait 返回 nil：ssh 因端口占用退出，换端口重试（docs/04 §4）。
            } catch let error as MySQLError {
                fatal = error
                break
            } catch {
                fatal = MySQLError.connect(step: .sshTunnel,
                                           message: "SSH 隧道建立失败",
                                           detail: String(describing: error))
                break
            }
        }

        // start() 与 stop() 在 await 点交错时，以 stop 为准，不覆盖 stopped 状态。
        if isStopping {
            state = .stopped
            throw MySQLError.cancelled
        }

        let error = fatal ?? classifyFailure(stderrTail)
        lastError = error
        state = .failed(reason: error.title)
        throw error
    }

    /// 启动一次尝试。返回就绪端口；返回 nil 表示「端口占用，可换端口重试」。
    private func launchAndWait(port: Int) async throws -> Int? {
        let plan = SSHCommandBuilder.build(config: config,
                                           localPort: port,
                                           remoteHost: remoteHost,
                                           remotePort: remotePort,
                                           password: password,
                                           passphrase: passphrase)

        var environment = plan.environment
        if let script = plan.askpassScript {
            // 一次性 askpass 脚本落盘 0700；密码走环境变量，脚本内不含明文（docs/04 §5）。
            let url = try makeAskpassFileURL()
            try fileSystem.writeAtomically(Data(script.utf8), to: url, permissions: 0o700)
            askpassURL = url
            environment["SSH_ASKPASS"] = url.path
        } else {
            askpassURL = nil
        }

        processExited = false
        stderrTail = ""

        let process: any RunningProcess
        do {
            process = try runner.launch(executable: plan.executable,
                                        arguments: plan.arguments,
                                        environment: environment,
                                        onOutput: { chunk in
                                            Task { await self.appendStderr(chunk) }
                                        },
                                        onExit: { status in
                                            Task { await self.handleProcessExit(status) }
                                        })
        } catch {
            removeAskpassFile()
            throw MySQLError.connect(step: .sshTunnel,
                                     message: "无法启动 SSH 进程",
                                     detail: String(describing: error))
        }
        self.process = process

        // 就绪判定不用固定 sleep：轮询 127.0.0.1:<port> 能否 TCP connect（docs/04 §6）。
        var waited: TimeInterval = 0
        while waited < Self.readyTimeout {
            if isStopping { throw MySQLError.cancelled }
            if processExited {
                if Self.looksLikePortConflict(stderrTail) { return nil }
                throw classifyFailure(stderrTail)
            }
            if Self.probeLocalPort(port) {
                if isStopping { throw MySQLError.cancelled }
                if processExited { throw classifyFailure(stderrTail) }
                return port
            }
            try await clock.sleep(seconds: Self.pollInterval)
            waited += Self.pollInterval
        }

        throw MySQLError.connect(step: .sshTunnel,
                                 message: "SSH 隧道建立超时（\(Int(Self.readyTimeout)) 秒）",
                                 detail: stderrTail.isEmpty ? nil : stderrTail)
    }

    // MARK: - 停止

    /// `terminate()` → 等 2s → 仍存活则 `SIGKILL`（docs/04 §6）。
    func stop() async {
        isStopping = true
        processExited = true  // 让可能在运行的 start() 轮询立即结束
        state = .stopped

        if let process, process.isRunning {
            process.terminate()
            var waited: TimeInterval = 0
            while process.isRunning && waited < Self.gracefulStopTimeout {
                try? await clock.sleep(seconds: Self.pollInterval)
                waited += Self.pollInterval
            }
            if process.isRunning { process.kill() }
        }

        self.process = nil
        removeAskpassFile()
    }

    // MARK: - 进程回调

    private func appendStderr(_ chunk: String) {
        stderrTail += chunk
        if stderrTail.count > Self.stderrTailLimit {
            stderrTail = String(stderrTail.suffix(Self.stderrTailLimit))
        }
    }

    private func handleProcessExit(_ status: Int32) {
        processExited = true
        guard !isStopping else { return }

        switch state {
        case .starting:
            break  // start() 的轮询会读到 processExited 并据此分类错误
        case .ready:
            // 隧道意外断开：当前 MySQLSession 必然也断；标记失败，不自动重连（L7）。
            let message = "SSH 隧道已断开"
            lastError = MySQLError.connect(step: .sshTunnel,
                                           message: message,
                                           detail: stderrTail.isEmpty ? nil : stderrTail)
            state = .failed(reason: message)
        default:
            break
        }
    }

    // MARK: - 错误分类（docs/04 §4、specs/10 §5）

    /// 把 ssh stderr 归类成用户可见的中文错误。原始输出始终放进 `detail`。
    private func classifyFailure(_ stderr: String) -> MySQLError {
        let detail = stderr.isEmpty ? nil : stderr
        let hostLabel = "\(config.host):\(config.port)"

        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            // 指纹变化必须失败并展示警告，不静默忽略（docs/04 §5、L8）。
            return .connect(step: .sshTunnel,
                            message: "服务器的 SSH 指纹与本地记录不一致。这可能意味着服务器被重装过，也可能存在安全风险。",
                            detail: detail)
        }
        if stderr.contains("Permission denied") {
            let message: String
            switch config.authMethod {
            case .privateKey:
                message = "SSH 认证失败：私钥需要口令，或密钥未被接受"
            default:
                message = "SSH 认证失败：Permission denied (password)."
            }
            return .connect(step: .sshTunnel, message: message, detail: detail)
        }
        if stderr.contains("Connection timed out") || stderr.contains("Operation timed out") {
            return .connect(step: .sshTunnel,
                            message: "无法连接到 SSH 主机 \(hostLabel)（连接超时）",
                            detail: detail)
        }
        if stderr.contains("Connection refused") {
            return .connect(step: .sshTunnel,
                            message: "无法连接到 SSH 主机 \(hostLabel)（连接被拒绝）",
                            detail: detail)
        }
        if stderr.contains("connect_to") && stderr.contains("failed") {
            return .connect(step: .sshTunnel,
                            message: "SSH 隧道建立成功，但无法从跳板机访问 \(remoteHost):\(remotePort)",
                            detail: detail)
        }
        if Self.looksLikePortConflict(stderr) {
            return .connect(step: .sshTunnel,
                            message: "本地端口被占用，SSH 隧道建立失败",
                            detail: detail)
        }
        // 兜底（例如跳板机上没有权限）：原样展示 SSH 的错误输出（specs/10 §5）。
        let lastLine = stderr.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return .connect(step: .sshTunnel,
                        message: lastLine.isEmpty ? "SSH 隧道建立失败" : lastLine,
                        detail: detail)
    }

    private static func looksLikePortConflict(_ text: String) -> Bool {
        text.contains("Address already in use") || text.contains("cannot listen to port")
    }

    // MARK: - 辅助

    /// 就绪判定：能否 TCP connect 到 `127.0.0.1:<port>`。
    ///
    /// 用非阻塞 BSD socket：回环上若没有监听者会立刻返回 ECONNREFUSED，
    /// 有监听者则 connect 返回 0 或 EINPROGRESS（连接正在建立，说明端口已占用）。
    private static func probeLocalPort(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        return errno == EINPROGRESS || errno == EISCONN
    }

    private func makeAskpassFileURL() throws -> URL {
        try fileSystem.ensureDirectory(at: fileSystem.temporaryDirectory)
        return fileSystem.temporaryDirectory
            .appendingPathComponent("ssh-askpass-\(UUID().uuidString).sh")
    }

    private func removeAskpassFile() {
        guard let askpassURL else { return }
        try? fileSystem.removeItemIfExists(at: askpassURL)
        self.askpassURL = nil
    }
}
