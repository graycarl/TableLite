import Foundation

// MARK: - 查询历史

/// 查询历史条目。只记录来自 SQL 编辑器的语句。
///
/// 字段见 `docs/tech-designs/02-persistence.md` §4、`specs/06-query-editor.md` §5。
public struct QueryHistoryEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: Int64
    public var connectionID: UUID
    public var database: String?
    public var sql: String
    public var executedAt: Date
    public var succeeded: Bool
    public var durationMilliseconds: Int
    /// 查询返回的行数（非查询语句为 nil）。
    public var returnedRowCount: Int?
    /// 影响行数（非查询语句为 nil）。
    public var affectedRows: Int?
    public var errorCode: UInt32?
    public var errorMessage: String?

    public init(
        id: Int64,
        connectionID: UUID,
        database: String? = nil,
        sql: String,
        executedAt: Date,
        succeeded: Bool,
        durationMilliseconds: Int,
        returnedRowCount: Int? = nil,
        affectedRows: Int? = nil,
        errorCode: UInt32? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.sql = sql
        self.executedAt = executedAt
        self.succeeded = succeeded
        self.durationMilliseconds = durationMilliseconds
        self.returnedRowCount = returnedRowCount
        self.affectedRows = affectedRows
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

// MARK: - Console Log

/// Console Log 标签：用户发起 vs 客户端自动发出。
public enum ConsoleLogTag: String, Sendable, Codable, CaseIterable, Hashable {
    case data
    case meta
}

/// 一条 Console Log。记录**所有**下发到服务器的语句。
///
/// 字段见 `docs/tech-designs/02-persistence.md` §5、`specs/06-query-editor.md` §6。
public struct ConsoleLogEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: UInt64
    public var timestamp: Date
    public var tag: ConsoleLogTag
    public var database: String?
    public var sql: String
    public var durationMilliseconds: Int?
    public var returnedRowCount: Int?
    public var affectedRows: Int?
    public var errorCode: UInt32?
    public var errorMessage: String?
    public var isCancelled: Bool

    public init(
        id: UInt64,
        timestamp: Date,
        tag: ConsoleLogTag,
        database: String? = nil,
        sql: String,
        durationMilliseconds: Int? = nil,
        returnedRowCount: Int? = nil,
        affectedRows: Int? = nil,
        errorCode: UInt32? = nil,
        errorMessage: String? = nil,
        isCancelled: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tag = tag
        self.database = database
        self.sql = sql
        self.durationMilliseconds = durationMilliseconds
        self.returnedRowCount = returnedRowCount
        self.affectedRows = affectedRows
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.isCancelled = isCancelled
    }

    public var isSuccess: Bool { errorCode == nil && !isCancelled }
}

/// 固定容量的环形缓冲。Console Log 默认容量 5000（`02-persistence.md` §5）。
///
/// 纯值类型，方便单测；UI 侧持有可变副本。
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element]

    public init(capacity: Int) {
        precondition(capacity > 0, "容量必须为正")
        self.capacity = capacity
        self.storage = []
        self.storage.reserveCapacity(min(capacity, 4096))
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    /// 按加入顺序返回全部元素（旧的在前）。
    public var elements: [Element] { storage }

    /// 追加一个元素；超出容量时丢弃最旧的。
    public mutating func append(_ element: Element) {
        if storage.count == capacity {
            storage.removeFirst()
        }
        storage.append(element)
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }
}

extension RingBuffer: Equatable where Element: Equatable {}
