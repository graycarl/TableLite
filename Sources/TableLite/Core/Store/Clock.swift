import Foundation

/// 时间注入点。
///
/// 决策见 `15-testing.md` §3：空闲回收、TTL、草稿防抖、超时轮询都走 `Clock`，
/// 业务代码里禁止直接 `Date()`。
public protocol Clock: Sendable {
    var now: Date { get }
}

/// 真实时钟。
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// 测试用固定时钟。
public struct FixedClock: Clock {
    public let instant: Date

    public init(_ instant: Date) {
        self.instant = instant
    }

    public var now: Date { instant }
}
