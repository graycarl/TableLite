import Darwin
import Foundation

/// 子进程抽象，便于测试注入（T12 / docs/tech-designs/15-testing.md §3）。
///
/// **硬约束：`Process` 只能在 `LiveProcessRunner` 里出现**，其他任何地方都不允许直接
/// 启动进程。见 AGENTS.md 代码约定。
protocol ProcessRunning: Sendable {
    /// 启动并返回句柄；`onOutput` 收到 stderr 的增量文本，`onExit` 在进程结束时回调一次。
    func launch(executable: URL,
                arguments: [String],
                environment: [String: String],
                onOutput: @escaping @Sendable (String) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningProcess
}

/// 已启动进程的最小控制面。
protocol RunningProcess: Sendable {
    var processIdentifier: Int32 { get }
    func terminate()
    func kill()
    var isRunning: Bool { get }
}

/// 真实实现：`Foundation.Process`。唯一直接使用 `Process` 的地方。
struct LiveProcessRunner: ProcessRunning {

    func launch(executable: URL,
                arguments: [String],
                environment: [String: String],
                onOutput: @escaping @Sendable (String) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws -> RunningProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // 保留父进程环境（HOME / PATH 等，ssh 要靠 HOME 读 ~/.ssh/config），
        // 再叠加 ASKPASS 相关变量。
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        // 没有 tty：stdin / stdout 丢弃，stderr 收进来解析（docs/04 §1、§7）。
        let errorPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        let handle = LiveRunningProcess(process: process, errorPipe: errorPipe, onExit: onExit)

        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onOutput(text)
        }
        // 强引用 handle：退出回调只触发一次，`markExited` 里会把 handler 置空从而打破循环引用。
        process.terminationHandler = { [handle] finished in
            handle.markExited(status: finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        return handle
    }
}

/// `Foundation` 的 `Process` / `Pipe` / `FileHandle` 都不是 `Sendable`。
/// 这里用一把锁把它们串行化，退出状态只通过锁保护的标志读取；这正是 AGENTS.md 允许的
/// `@unchecked Sendable` 例外：包装系统对象 + 明确加锁。注意：**绝不持锁调用
/// `terminate()` / `kill()`**，因为退出回调会重新获取同一把锁。
final class LiveRunningProcess: RunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let errorPipe: Pipe
    private let onExitHandler: @Sendable (Int32) -> Void
    private var running = true

    init(process: Process, errorPipe: Pipe, onExit: @escaping @Sendable (Int32) -> Void) {
        self.process = process
        self.errorPipe = errorPipe
        self.onExitHandler = onExit
    }

    var processIdentifier: Int32 {
        lock.lock(); defer { lock.unlock() }
        return process.processIdentifier
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = running
        lock.unlock()
        guard shouldTerminate else { return }
        process.terminate()  // SIGTERM
    }

    func kill() {
        lock.lock()
        let shouldKill = running
        let pid = process.processIdentifier
        lock.unlock()
        guard shouldKill, pid > 0 else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 由 `Process.terminationHandler` 调用，只生效一次。
    func markExited(status: Int32) {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()

        errorPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil  // 打破 handle -> process -> handler -> handle
        onExitHandler(status)
    }
}
