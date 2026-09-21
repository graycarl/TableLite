import Foundation
import SQLite3

/// 绑定到 SQL 语句的值。
enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

/// libsqlite3 的最小封装。
///
/// 只在 `QueryHistoryStore` 的 actor 内使用，不跨隔离域，因此不需要 `Sendable`。
/// 打开时使用 `SQLITE_OPEN_FULLMUTEX`（serialized），与 actor 的互斥叠加也不会出问题。
final class SQLiteDatabase {

    /// `SQLITE_TRANSIENT`：让 SQLite 复制传入的字符串，调用方可以立刻释放。
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    let path: String

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库文件"
            if let handle { sqlite3_close_v2(handle) }
            StoreLog.error("打开 SQLite 数据库失败 \(path)：\(message)")
            throw StoreDatabaseError.sqlite(code: status, message: message)
        }
        self.handle = handle
        self.path = path
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
        } catch {
            StoreLog.error("初始化 SQLite 失败 \(path)：\(error)")
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    // MARK: - 执行

    func execute(_ sql: String) throws {
        guard let handle else { throw StoreDatabaseError.closed }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if let errorPointer {
            let message = String(cString: errorPointer)
            sqlite3_free(errorPointer)
            guard status == SQLITE_OK else {
                StoreLog.error("执行 SQL 失败：\(message)")
                throw StoreDatabaseError.sqlite(code: status, message: message)
            }
        }
        guard status == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            StoreLog.error("执行 SQL 失败：\(message)")
            throw StoreDatabaseError.sqlite(code: status, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw StoreDatabaseError.closed }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            StoreLog.error("准备 SQL 失败：\(message)")
            throw StoreDatabaseError.sqlite(code: status, message: message)
        }
        return SQLiteStatement(handle: statement)
    }

    var lastInsertRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    /// 读取 `PRAGMA user_version`（`02-persistence.md` §9）。
    var userVersion: Int32 {
        guard let handle else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }
}

/// 已准备的语句。`deinit` 负责 `sqlite3_finalize`。
final class SQLiteStatement {

    private var handle: OpaquePointer?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let handle { sqlite3_finalize(handle) }
    }

    func bind(_ values: [SQLiteValue]) throws {
        guard let handle else { throw StoreDatabaseError.closed }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(handle, index)
            case .int(let number):
                status = sqlite3_bind_int64(handle, index, number)
            case .double(let number):
                status = sqlite3_bind_double(handle, index, number)
            case .text(let text):
                status = sqlite3_bind_text(handle, index, text, -1, SQLiteDatabase.transient)
            }
            guard status == SQLITE_OK else {
                StoreLog.error("SQL 参数绑定失败（第 \(index) 个参数）")
                throw StoreDatabaseError.bindingFailed
            }
        }
    }

    /// 推进一次：`true` 表示有行，`false` 表示执行完成。
    @discardableResult
    func step() throws -> Bool {
        guard let handle else { throw StoreDatabaseError.closed }
        let status = sqlite3_step(handle)
        switch status {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            let message = String(cString: sqlite3_errmsg(sqlite3_db_handle(handle)))
            StoreLog.error("执行语句失败：\(message)")
            throw StoreDatabaseError.sqlite(code: status, message: message)
        }
    }

    func reset() {
        guard let handle else { return }
        sqlite3_reset(handle)
    }

    // MARK: - 取值

    func isNull(_ index: Int32) -> Bool {
        guard let handle else { return true }
        return sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func text(_ index: Int32) -> String? {
        guard let handle, !isNull(index), let pointer = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: pointer)
    }

    func int64(_ index: Int32) -> Int64 {
        guard let handle else { return 0 }
        return sqlite3_column_int64(handle, index)
    }

    func int(_ index: Int32) -> Int {
        Int(int64(index))
    }

    func double(_ index: Int32) -> Double {
        guard let handle else { return 0 }
        return sqlite3_column_double(handle, index)
    }
}
