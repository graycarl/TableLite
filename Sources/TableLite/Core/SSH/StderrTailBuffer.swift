import Foundation

/// 只保留最后 N 字节的环形/滑窗缓冲。
///
/// SSH 失败时 stderr 是排查的唯一线索（`docs/tech-designs/05-session-management.md` §3），
/// 但 ssh 可能输出很多行，只保留尾部即可，见 `docs/tech-designs/04-ssh-tunnel.md` §3、§6。
public struct StderrTailBuffer: Sendable, Equatable {
    /// 保留的字节上限。默认 4 KB。
    public let capacity: Int

    private var storage: Data

    public init(capacity: Int = 4096) {
        precondition(capacity > 0, "capacity 必须为正")
        self.capacity = capacity
        self.storage = Data()
    }

    /// 追加一段原始字节；超出 `capacity` 时从头部丢弃最旧的数据。
    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        // 单次数据就超过容量时，没必要先拼进来再裁剪。
        if data.count >= capacity {
            storage = Data(data.suffix(capacity))
            return
        }
        storage.append(data)
        if storage.count > capacity {
            storage.removeSubrange(0..<(storage.count - capacity))
        }
    }

    /// 当前保留的原始字节。
    public var data: Data { storage }

    /// 以 UTF-8 宽松解码成文本（非法字节替换为 U+FFFD，不丢内容）。
    public var string: String { String(decoding: storage, as: UTF8.self) }

    public var isEmpty: Bool { storage.isEmpty }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }
}
