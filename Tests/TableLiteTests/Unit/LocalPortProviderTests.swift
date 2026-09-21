import Foundation
import XCTest
@testable import TableLite

/// 本地端口分配与探测。
///
/// 见 `docs/tech-designs/04-ssh-tunnel.md` §4、§6。
/// 这些用例只碰本机回环 socket，不依赖外部服务。
final class LocalPortProviderTests: XCTestCase {

    private enum SocketError: Error {
        case operationFailed
    }

    // MARK: 分配

    func testAllocatedPortIsActuallyBindable() async throws {
        let provider = LiveLocalPortProvider()
        let port = try await provider.allocateLocalPort()
        XCTAssertGreaterThan(port, 0)

        // 申请到的端口应能立刻被再次 bind（说明它确实空闲）。
        let (descriptor, _) = try bindLoopback(port: port, listening: false)
        close(descriptor)
    }

    func testAllocationsAreUsable() async throws {
        let provider = LiveLocalPortProvider()
        let first = try await provider.allocateLocalPort()
        let second = try await provider.allocateLocalPort()
        // 端口只在极小概率下相同，但两者都必须可用。
        let (descriptorA, _) = try bindLoopback(port: first, listening: false)
        let (descriptorB, _) = try bindLoopback(port: second, listening: false)
        close(descriptorA)
        close(descriptorB)
    }

    // MARK: 探测

    func testCanConnectTrueForListeningPort() async throws {
        let (descriptor, port) = try bindLoopback(port: nil, listening: true)
        defer { close(descriptor) }

        let provider = LiveLocalPortProvider()
        let reachable = await provider.canConnect(toLocalPort: port)
        XCTAssertTrue(reachable)
    }

    func testCanConnectFalseForBoundButNotListeningPort() async throws {
        // bind 但不 listen：connect 会被拒绝，用于模拟「ssh 还没起来」。
        let (descriptor, port) = try bindLoopback(port: nil, listening: false)
        defer { close(descriptor) }

        let provider = LiveLocalPortProvider()
        let reachable = await provider.canConnect(toLocalPort: port)
        XCTAssertFalse(reachable)
    }

    // MARK: - 工具

    /// bind 一个回环端口；`port == nil` 时由系统分配。
    private func bindLoopback(port: UInt16?, listening: Bool) throws -> (Int32, UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.operationFailed }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = (port ?? 0).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw SocketError.operationFailed }

            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { throw SocketError.operationFailed }

            if listening, listen(descriptor, 1) != 0 {
                throw SocketError.operationFailed
            }
            return (descriptor, UInt16(bigEndian: address.sin_port))
        } catch {
            close(descriptor)
            throw error
        }
    }
}
