import Foundation

/// `SSH_ASKPASS` 一次性脚本。
///
/// 见 `docs/tech-designs/04-ssh-tunnel.md` §5、`specs/10-ssh-tunnel.md` §3.3：
/// - 用 `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` 强制走 askpass（本进程没有 tty）；
/// - 密码通过**子进程环境变量**传进脚本，不写进脚本文件；
/// - 脚本权限 `0700`，用完即删；
/// - 该机制会让 ssh 对所有提问都调用 askpass。正常情况下 `accept-new` 已自动接受新指纹；
///   若出现 known_hosts 冲突，askpass 会返回密码导致 ssh 失败退出——这是**期望行为**，
///   不静默绕过安全告警（L8）。
public struct SSHAskpassScript: Sendable {

    /// 传给子进程的环境变量名：askpass 脚本从这里读取口令。
    public static let secretEnvironmentKey = "TABLELITE_SSH_ASKPASS_SECRET"
    public static let scriptFileName = "askpass.sh"

    /// 脚本所在的一次性临时目录（用完整体删除）。
    public let directoryURL: URL
    public let scriptURL: URL
    /// 需要合并进 ssh 子进程的环境变量。
    public let environment: [String: String]

    public init(directoryURL: URL, scriptURL: URL, environment: [String: String]) {
        self.directoryURL = directoryURL
        self.scriptURL = scriptURL
        self.environment = environment
    }

    /// askpass 脚本内容（纯逻辑，可单测）。口令只从环境变量读，不落盘。
    public static func scriptContent() -> String {
        """
        #!/bin/sh
        # TableLite 一次性 SSH askpass 脚本。口令经环境变量传入，绝不写入本文件。
        printf '%s\\n' "$\(secretEnvironmentKey)"
        """
    }

    /// 拼装 askpass 需要的环境变量（纯逻辑，可单测）。
    public static func makeEnvironment(secret: String, scriptPath: String) -> [String: String] {
        [
            "SSH_ASKPASS": scriptPath,
            "SSH_ASKPASS_REQUIRE": "force",
            secretEnvironmentKey: secret,
        ]
    }

    /// 在临时目录里创建 0700 的 askpass 脚本。
    ///
    /// - Parameter baseDirectory: 临时目录根；默认 `FileManager.default.temporaryDirectory`，测试可覆盖。
    public static func create(secret: String, baseDirectory: URL? = nil) throws -> SSHAskpassScript {
        let fileManager = FileManager.default
        let root = baseDirectory ?? fileManager.temporaryDirectory
        let directory = root.appendingPathComponent("TableLite-SSH-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let script = directory.appendingPathComponent(scriptFileName)
        try scriptContent().write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return SSHAskpassScript(
            directoryURL: directory,
            scriptURL: script,
            environment: makeEnvironment(secret: secret, scriptPath: script.path)
        )
    }

    /// 删除整个一次性目录。幂等，失败不抛。
    public func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
