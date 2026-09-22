import Foundation

// MARK: - 错误

/// SSH 隧道的错误类型。
///
/// 与 MySQL 侧错误严格区分（`docs/tech-designs/05-session-management.md` §3、
/// `04-ssh-tunnel.md` §7）：UI 文案不能都写成「连接失败」。
/// 指纹变化单独成一种，绝不与普通连接失败混同（L8）。
public enum SSHTunnelError: Error, Sendable, Equatable {
    /// 找不到 `/usr/bin/ssh`。
    case sshExecutableMissing(path: String)
    /// 配置不完整或非法，进程还没启动。
    case invalidConfiguration(reason: String)
    /// 无法从系统申请本地临时端口。
    case portAllocationFailed(reason: String)
    /// `Process.run()` 失败。
    case processLaunchFailed(reason: String)
    /// 本地端口在 ssh 绑定前被别人占用；可换端口重试（`04` §4）。
    case localPortInUse(stderrTail: String)
    /// 就绪轮询在 15s 内没有成功，且进程未退出。
    case startupTimedOut(stderrTail: String)
    /// 连不上 SSH 主机（超时、拒绝、DNS 解析失败等）。
    case connectionFailed(stderrTail: String)
    /// 认证失败（用户名/密码错误等）。
    case authenticationFailed(stderrTail: String)
    /// 私钥无法加载、权限不对、需要口令等。
    case privateKeyRejected(stderrTail: String)
    /// 主机指纹与 known_hosts 记录不一致。**必须明确失败**。
    case hostKeyChanged(stderrTail: String)
    /// 隧道建立后断开（进程退出或健康检查失败）。
    case tunnelClosed(stderrTail: String)

    /// 错误的 stderr 尾部（最后 4 KB）；非 stderr 类错误返回空串。
    public var stderrTail: String {
        switch self {
        case .localPortInUse(let tail),
             .startupTimedOut(let tail),
             .connectionFailed(let tail),
             .authenticationFailed(let tail),
             .privateKeyRejected(let tail),
             .hostKeyChanged(let tail),
             .tunnelClosed(let tail):
            return tail
        case .sshExecutableMissing, .invalidConfiguration, .portAllocationFailed, .processLaunchFailed:
            return ""
        }
    }

    /// 是否是「主机指纹变化」。UI 据此弹出安全警告面板（`specs/10-ssh-tunnel.md` §4）。
    public var isHostKeyChanged: Bool {
        if case .hostKeyChanged = self { return true }
        return false
    }

    /// 是否可以换一个本地端口重试。
    public var isRetryableLocalPort: Bool {
        if case .localPortInUse = self { return true }
        return false
    }

    /// 面向用户的中文说明。UI 另需把 `stderrTail` 放进「查看详细输出」。
    public var displayMessage: String {
        switch self {
        case .sshExecutableMissing(let path):
            return "找不到系统 SSH 程序（\(path)）"
        case .invalidConfiguration(let reason):
            return "SSH 配置不完整：\(reason)"
        case .portAllocationFailed(let reason):
            return "无法分配本地端口：\(reason)"
        case .processLaunchFailed(let reason):
            return "无法启动 SSH 进程：\(reason)"
        case .localPortInUse:
            return "本地端口被占用，正在重试"
        case .startupTimedOut:
            return "SSH 隧道建立超时"
        case .connectionFailed:
            return "无法连接到 SSH 主机"
        case .authenticationFailed:
            return "SSH 认证失败"
        case .privateKeyRejected:
            return "SSH 认证失败：私钥需要口令，或密钥未被接受"
        case .hostKeyChanged:
            return "服务器的 SSH 指纹与本地记录不一致。这可能意味着服务器被重装过，也可能存在安全风险。"
        case .tunnelClosed:
            return "SSH 隧道已断开"
        }
    }
}

extension SSHTunnelError: LocalizedError {
    public var errorDescription: String? { displayMessage }
}

// MARK: - stderr 分类

/// 把 ssh 的 stderr 尾部归类成结构化错误。
///
/// 纯函数，可单元测试。ssh 拿不到结构化错误（`04` §1 的「代价」），
/// 只能在文本上做保守的分类：分不出来的一律归到 `connectionFailed`，
/// 原样保留 stderr 交给用户。
public enum SSHStderrClassifier {

    public static func classify(
        stderrTail: String,
        exitStatus: Int32?,
        authMethod: SSHAuthMethod
    ) -> SSHTunnelError {
        let text = stderrTail.lowercased()

        // 1) 主机指纹变化 —— 最高优先级，绝不能落到泛化的连接失败里。
        if text.contains("remote host identification has changed")
            || text.contains("host key verification failed")
            || text.contains("host key for")
            || text.contains("offending") && text.contains("known_hosts") {
            return .hostKeyChanged(stderrTail: stderrTail)
        }

        // 2) 本地端口被占用（ExitOnForwardFailure + bind 失败）。可换端口重试。
        if text.contains("address already in use")
            || text.contains("cannot listen to port")
            || text.contains("could not request local forwarding")
            || text.contains("bind: ") {
            return .localPortInUse(stderrTail: stderrTail)
        }

        // 3) 认证相关。
        if text.contains("permission denied") || text.contains("authentication failed") {
            if authMethod == .privateKey, looksLikePrivateKeyProblem(text) {
                return .privateKeyRejected(stderrTail: stderrTail)
            }
            return .authenticationFailed(stderrTail: stderrTail)
        }
        if authMethod == .privateKey, looksLikePrivateKeyProblem(text) {
            return .privateKeyRejected(stderrTail: stderrTail)
        }
        if text.contains("too many authentication failures") {
            return .authenticationFailed(stderrTail: stderrTail)
        }

        // 4) 网络连通性问题。
        let connectivityMarkers = [
            "connection timed out",
            "connection refused",
            "no route to host",
            "network is unreachable",
            "operation timed out",
            "could not resolve hostname",
            "name or service not known",
            "connect to host",
            "connection closed by remote host",
            "connection reset by peer",
            "kex_exchange_identification",
            "connection closed by",
            "broken pipe",
        ]
        if connectivityMarkers.contains(where: text.contains) {
            return .connectionFailed(stderrTail: stderrTail)
        }

        // 5) 兜底：原样保留 stderr，按连接失败展示。
        return .connectionFailed(stderrTail: stderrTail)
    }

    private static func looksLikePrivateKeyProblem(_ lowercasedStderr: String) -> Bool {
        let markers = [
            "load key",
            "invalid format",
            "bad permissions",
            "excess permission",
            "permissions are too open",
            "no such identity",
            "identity file",
            "passphrase",
            "encrypted",
        ]
        return markers.contains(where: lowercasedStderr.contains)
    }
}
