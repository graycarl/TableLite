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

// MARK: - 私钥是否需要口令

/// 判断私钥文件是否为「加密（带口令）」格式。
///
/// `specs/10-ssh-tunnel.md` §3.2：私钥有口令时，第一次连接要弹输入框。
/// 在启动 ssh 前先看一眼文件，可以避免为未加密的私钥多余地弹窗
/// （密码 / 口令只从用户输入进 Keychain，本类型不碰、缓存、记录任何口令）。
///
/// 纯逻辑，可单元测试。读不到文件时按「未加密」处理，交给 ssh 自己报错。
public enum SSHPrivateKeyInspector {

    /// 读文件后判断。
    public static func isEncrypted(path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return isEncrypted(pem: text)
    }

    /// 根据文件内容判断。
    public static func isEncrypted(pem: String) -> Bool {
        // 老 PEM（`Proc-Type: 4,ENCRYPTED` + `DEK-Info`）与 PKCS#8 加密块。
        if pem.contains("BEGIN ENCRYPTED PRIVATE KEY") { return true }
        if pem.contains("Proc-Type: 4,ENCRYPTED") { return true }
        if pem.contains("DEK-Info:") { return true }

        // OpenSSH 新格式：解出 ciphername，`none` 表示未加密。
        guard let body = base64Body(
            in: pem,
            begin: "-----BEGIN OPENSSH PRIVATE KEY-----",
            end: "-----END OPENSSH PRIVATE KEY-----"
        ),
              let data = Data(base64Encoded: body),
              let cipher = openSSHCipherName(in: data) else {
            return false
        }
        return cipher != "none"
    }

    /// `openssh-key-v1\0` 之后第一个 string 是 ciphername。
    static func openSSHCipherName(in data: Data) -> String? {
        let magic = Array("openssh-key-v1\u{0}".utf8)
        guard data.count >= magic.count + 4 else { return nil }
        guard Array(data.prefix(magic.count)) == magic else { return nil }
        let base = data.startIndex + magic.count
        let length = Int(data[base]) << 24
            | Int(data[base + 1]) << 16
            | Int(data[base + 2]) << 8
            | Int(data[base + 3])
        guard length >= 0, data.count >= magic.count + 4 + length else { return nil }
        let start = base + 4
        return String(decoding: data[start..<(start + length)], as: UTF8.self)
    }

    private static func base64Body(in pem: String, begin: String, end: String) -> String? {
        guard let beginRange = pem.range(of: begin),
              let endRange = pem.range(of: end, range: beginRange.upperBound..<pem.endIndex) else {
            return nil
        }
        return pem[beginRange.upperBound..<endRange.lowerBound].filter { !$0.isWhitespace }
    }
}
