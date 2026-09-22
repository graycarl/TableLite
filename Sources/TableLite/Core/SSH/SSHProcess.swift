import Foundation

// MARK: - 抽象

/// 一个正在运行的子进程句柄。
///
/// 全部方法都是 `async`，这样真实实现可以是一个 actor 持有 `Process`
/// （`Process` 不是 `Sendable`），测试替身也可以是一个 actor，
/// 不需要任何 `@unchecked Sendable`。
public protocol SSHProcessHandle: Sendable {
    var processIdentifier: Int32 { get async }

    func isRunning() async -> Bool

    /// 当前已捕获的 stderr（最后 4 KB）。
    func takeStderr() async -> Data

    /// 非阻塞查询退出状态；返回 `nil` 表示仍在运行。
    func pollExitStatus() async -> Int32?

    /// 发送 SIGTERM。
    func terminate() async

    /// 发送 SIGKILL。
    func forceKill() async
}

/// 启动 `/usr/bin/ssh` 子进程。T12 注入点，测试用脚本化替身。
public protocol SSHProcessRunning: Sendable {
    /// 启动命令。环境变量会覆盖当前进程的环境。
    /// 失败时抛 `SSHTunnelError`（`sshExecutableMissing` / `processLaunchFailed`）。
    func launch(_ command: SSHCommand, environment: [String: String]) async throws -> SSHProcessHandle
}

// MARK: - 真实实现

/// 用 `Process` 启动系统 ssh。
public struct LiveSSHProcessRunner: SSHProcessRunning {

    public init() {}

    public func launch(_ command: SSHCommand, environment: [String: String]) async throws -> SSHProcessHandle {
        guard FileManager.default.isExecutableFile(atPath: command.executablePath) else {
            throw SSHTunnelError.sshExecutableMissing(path: command.executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        // 继承当前环境（SSH_AUTH_SOCK、HOME 等），再叠加 askpass 相关变量。
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // stdout 无用；stdin 置空，ssh 不可能从终端读输入。
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let handle = LiveSSHProcessHandle(
            process: process,
            stderrReader: stderrPipe.fileHandleForReading
        )
        await handle.installHandlers()

        do {
            try process.run()
        } catch {
            throw SSHTunnelError.processLaunchFailed(reason: error.localizedDescription)
        }
        return handle
    }
}

/// 真实进程句柄：actor 持有 `Process` 与 stderr 尾部缓冲。
public actor LiveSSHProcessHandle: SSHProcessHandle {

    private let process: Process
    private let stderrReader: FileHandle
    private var stderrTail: StderrTailBuffer
    private var exitStatus: Int32?
    private var handlersInstalled = false

    init(process: Process, stderrReader: FileHandle, stderrCapacity: Int = 4096) {
        self.process = process
        self.stderrReader = stderrReader
        self.stderrTail = StderrTailBuffer(capacity: stderrCapacity)
    }

    /// 必须在 `process.run()` 之前调用，避免漏掉立刻退出的情况。
    func installHandlers() {
        guard !handlersInstalled else { return }
        handlersInstalled = true

        stderrReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.appendStderr(data) }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            finished.terminationHandler = nil
            Task { await self?.markExited(status) }
        }
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public func isRunning() -> Bool { process.isRunning }

    public func takeStderr() -> Data { stderrTail.data }

    public func pollExitStatus() -> Int32? { exitStatus }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate() // SIGTERM
    }

    public func forceKill() {
        // pid > 0 防御：进程已退出时不要误伤 pid 0（进程组）。
        guard process.isRunning, process.processIdentifier > 0 else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    // MARK: - 私有

    private func appendStderr(_ data: Data) {
        stderrTail.append(data)
    }

    private func markExited(_ status: Int32) {
        // 退出后再同步读一次，保证最后一段 stderr 不丢（错误信息是唯一线索）。
        stderrReader.readabilityHandler = nil
        if let remaining = try? stderrReader.readToEnd(), !remaining.isEmpty {
            stderrTail.append(remaining)
        }
        if exitStatus == nil {
            exitStatus = status
        }
    }
}
