import Foundation

/// 本地临时端口的申请与探测。
///
/// `15-testing.md` §3 的 T12 可测试性注入点之一；本模块只抽这一层，
/// 真实实现走 BSD socket，测试用脚本化的替身。
public protocol LocalPortProviding: Sendable {
    /// 向系统申请一个当前空闲的本地端口（bind `127.0.0.1:0` 后立即释放）。
    ///
    /// 注意：从关闭 socket 到 ssh 真正 bind 之间有窗口期（`04` §4），
    /// 调用方需要在 ssh 因端口占用退出时重试。
    func allocateLocalPort() async throws -> UInt16

    /// 探测 `127.0.0.1:<port>` 是否已经可以 connect —— 隧道就绪判定用（`04` §6）。
    func canConnect(toLocalPort port: UInt16) async -> Bool
}

/// 真实实现：BSD socket。
public struct LiveLocalPortProvider: LocalPortProviding {

    /// 端口探测的超时。本地回环正常情况下毫秒级返回，这里给足余量。
    public var connectTimeoutMilliseconds: Int32

    public init(connectTimeoutMilliseconds: Int32 = 500) {
        self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
    }

    public func allocateLocalPort() async throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SSHTunnelError.portAllocationFailed(reason: lastSocketError())
        }
        defer { close(descriptor) }

        var address = LoopbackAddress.any
        let bound = withSockaddr(&address) { pointer, length in
            bind(descriptor, pointer, length)
        }
        guard bound == 0 else {
            throw SSHTunnelError.portAllocationFailed(reason: lastSocketError())
        }

        var assigned = LoopbackAddress.any
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withSockaddr(&assigned) { pointer, _ in
            getsockname(descriptor, pointer, &length)
        }
        guard named == 0 else {
            throw SSHTunnelError.portAllocationFailed(reason: lastSocketError())
        }

        let port = UInt16(bigEndian: assigned.sin_port)
        guard port > 0 else {
            throw SSHTunnelError.portAllocationFailed(reason: "系统返回的端口为 0")
        }
        return port
    }

    public func canConnect(toLocalPort port: UInt16) async -> Bool {
        probeConnect(port: port, timeoutMilliseconds: connectTimeoutMilliseconds)
    }

    // MARK: - 私有

    /// 非阻塞 connect + poll，避免探测卡住就绪轮询。
    private func probeConnect(port: UInt16, timeoutMilliseconds: Int32) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return false }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var address = LoopbackAddress.any
        address.sin_port = port.bigEndian

        let result = withSockaddr(&address) { pointer, length in
            connect(descriptor, pointer, length)
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollDescriptor, 1, timeoutMilliseconds)
        guard pollResult > 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }

    private func lastSocketError() -> String {
        String(cString: strerror(errno))
    }

    private func withSockaddr<T>(
        _ address: inout sockaddr_in,
        _ body: (UnsafeMutablePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

/// 只绑回环地址（`04` §4）。
private enum LoopbackAddress {
    static var any: sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }
}
