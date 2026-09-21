import Darwin
import Foundation

/// 本地端口分配。见 docs/tech-designs/04-ssh-tunnel.md §4。
///
/// 不预分配固定端口：bind `127.0.0.1:0` 让内核挑一个空闲端口，拿到端口号后立刻关闭
/// socket。从关闭 socket 到 ssh 真正绑定之间存在窗口期；若 ssh 因端口占用退出，
/// `SSHTunnel` 换端口重试最多 3 次兜底。
enum PortAllocator {

    /// 取一个当前空闲的本地端口。失败时抛 `MySQLError`。
    static func allocateLocalPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw portError("无法创建 socket", errno: errno)
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                              // 交给内核挑端口
        address.sin_addr.s_addr = inet_addr("127.0.0.1")  // 只绑回环

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw portError("无法绑定 127.0.0.1:0", errno: errno)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw portError("无法读取本地端口", errno: errno)
        }

        // sin_port / sin_addr 都是网络字节序。
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func portError(_ message: String, errno: Int32) -> MySQLError {
        let detail = String(cString: strerror(errno))
        return .connect(step: .sshTunnel, message: "无法分配本地端口：\(message)", detail: detail)
    }
}
