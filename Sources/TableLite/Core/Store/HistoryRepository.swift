import Foundation
import SQLite3

// MARK: - 错误

enum HistoryRepositoryError: Error, LocalizedError {
    case openFailed(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "无法打开查询历史数据库：\(message)"
        case .sqlite(let message):
            return "查询历史数据库出错：\(message)"
        }
    }
}

// MARK: - HistoryRepository

/// 查询历史，存 `history.sqlite3`（WAL）。见 docs/tech-designs/02-persistence.md §4。
///
/// - 只记录 SQL 编辑器的语句；是否记录由调用方决定，仓库本身不做过滤。
/// - 保留策略：默认最近 5000 条（`prune(keeping:)`）。
/// - 版本用 `PRAGMA user_version`（见同文档 §9）。
///
/// 所有访问都在 `@MainActor` 上串行，SQLite 句柄不需要额外加锁。
@MainActor
final class HistoryRepository {

    // MARK: 记录类型

    struct Entry: Hashable, Sendable, Identifiable {
        var id: Int64
        var connectionID: UUID
        var database: String?
        var sql: String
        var succeeded: Bool
        var elapsed: Duration
        var rowCount: Int?
        var affectedRows: Int?
        var errorCode: UInt32?
        var executedAt: Date
    }

    /// 待写入的一条记录（不含自增 id）。
    struct NewEntry: Hashable, Sendable {
        var connectionID: UUID
        var database: String? = nil
        var sql: String
        var succeeded: Bool
        var elapsed: Duration
        var rowCount: Int? = nil
        var affectedRows: Int? = nil
        var errorCode: UInt32? = nil
        /// 为 nil 时用注入的 `Clock.now`。
        var executedAt: Date? = nil
    }

    static let defaultMaxCount = 5000
    static let schemaVersion: Int32 = 1

    private let fileSystem: FileSystemLocator
    private let clock: Clock

    // C 句柄：所有访问都在 MainActor 上串行，deinit 需要非隔离访问，
    // 因此标 `nonisolated(unsafe)`（已写清理由，见 AGENTS.md 并发约定）。
    nonisolated(unsafe) private var handle: OpaquePointer?
    nonisolated(unsafe) private var openError: Error?

    init(fileSystem: FileSystemLocator, clock: Clock) {
        self.fileSystem = fileSystem
        self.clock = clock
        do {
            try open()
        } catch {
            openError = error
            storeLogger.error("history.sqlite3 打开失败：\(String(describing: error), privacy: .public)")
        }
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    var fileURL: URL {
        fileSystem.applicationSupportDirectory.appendingPathComponent("history.sqlite3")
    }

    // MARK: 写入 / 查询

    func record(_ entry: NewEntry) throws {
        let db = try database()
        let sql = """
            INSERT INTO history
            (connection_id, database_name, sql, succeeded, elapsed_ms, row_count, affected_rows, error_code, executed_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, entry.connectionID.uuidString)
        bindText(statement, 2, entry.database)
        bindText(statement, 3, entry.sql)
        sqlite3_bind_int(statement, 4, entry.succeeded ? 1 : 0)
        sqlite3_bind_double(statement, 5, Self.milliseconds(entry.elapsed))
        bindInt(statement, 6, entry.rowCount)
        bindInt(statement, 7, entry.affectedRows)
        bindUInt32(statement, 8, entry.errorCode)
        let executedAt = entry.executedAt ?? clock.now
        sqlite3_bind_double(statement, 9, executedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    /// 按时间倒序返回历史。`connectionID` / `search` 为 nil 时不过滤。
    func recent(connectionID: UUID?, search: String?, limit: Int) throws -> [Entry] {
        var sql = """
            SELECT id, connection_id, database_name, sql, succeeded, elapsed_ms,
                   row_count, affected_rows, error_code, executed_at
            FROM history
            """
        var clauses: [String] = []
        if connectionID != nil { clauses.append("connection_id = ?") }
        if let search, !search.isEmpty { clauses.append("sql LIKE '%' || ? || '%'") }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY executed_at DESC, id DESC LIMIT ?;"

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let connectionID {
            bindText(statement, index, connectionID.uuidString)
            index += 1
        }
        if let search, !search.isEmpty {
            bindText(statement, index, search)
            index += 1
        }
        sqlite3_bind_int64(statement, index, Int64(max(0, limit)))

        var result: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = columnText(statement, 1), let id = UUID(uuidString: text) else { continue }
            result.append(Entry(
                id: sqlite3_column_int64(statement, 0),
                connectionID: id,
                database: columnText(statement, 2),
                sql: columnText(statement, 3) ?? "",
                succeeded: sqlite3_column_int(statement, 4) != 0,
                elapsed: Self.duration(milliseconds: sqlite3_column_double(statement, 5)),
                rowCount: columnInt(statement, 6),
                affectedRows: columnInt(statement, 7),
                errorCode: columnUInt32(statement, 8),
                executedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
            ))
        }
        return result
    }

    func delete(id: Int64) throws {
        let db = try database()
        let statement = try prepare("DELETE FROM history WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    /// `connectionID` 为 nil 时清空全部。
    func clear(connectionID: UUID?) throws {
        if let connectionID {
            let db = try database()
            let statement = try prepare("DELETE FROM history WHERE connection_id = ?;")
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, connectionID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
        } else {
            try execute("DELETE FROM history;")
        }
    }

    /// 只保留最近 `maxCount` 条（按执行时间倒序）。
    func prune(keeping maxCount: Int = HistoryRepository.defaultMaxCount) throws {
        guard maxCount >= 0 else { return }
        let db = try database()
        let statement = try prepare("""
            DELETE FROM history WHERE id NOT IN (
                SELECT id FROM history ORDER BY executed_at DESC, id DESC LIMIT ?
            );
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(maxCount))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError(db) }
    }

    func count() throws -> Int {
        let db = try database()
        let statement = try prepare("SELECT COUNT(*) FROM history;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError(db) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: 打开与建表

    private func open() throws {
        try fileSystem.ensureDirectory(at: fileSystem.applicationSupportDirectory)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(fileURL.path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite 错误 \(code)"
            if let db { sqlite3_close_v2(db) }
            throw HistoryRepositoryError.openFailed(message)
        }
        handle = db
        // WAL：并发读更顺，落盘更稳。见 docs/tech-designs/02-persistence.md §4。
        try execute("PRAGMA journal_mode=WAL;")
        try createSchema()
    }

    private func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                connection_id TEXT NOT NULL,
                database_name TEXT,
                sql TEXT NOT NULL,
                succeeded INTEGER NOT NULL,
                elapsed_ms REAL NOT NULL,
                row_count INTEGER,
                affected_rows INTEGER,
                error_code INTEGER,
                executed_at REAL NOT NULL
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_history_executed_at ON history(executed_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_history_connection ON history(connection_id, executed_at DESC);")
        if try userVersion() == 0 {
            try execute("PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    private func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    // MARK: 底层辅助

    private func database() throws -> OpaquePointer {
        if let handle { return handle }
        if let openError { throw openError }
        throw HistoryRepositoryError.openFailed("数据库未打开")
    }

    private func execute(_ sql: String) throws {
        let db = try database()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorPointer)
            throw HistoryRepositoryError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        let db = try database()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        return statement
    }

    private func lastError(_ db: OpaquePointer) -> HistoryRepositoryError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }

    /// `SQLITE_TRANSIENT`：让 sqlite 立即复制字符串，桥接的临时指针随即失效。
    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bindInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func bindUInt32(_ statement: OpaquePointer?, _ index: Int32, _ value: UInt32?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(decodingCString: pointer, as: UTF8.self)
    }

    private func columnInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func columnUInt32(_ statement: OpaquePointer?, _ index: Int32) -> UInt32? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return UInt32(exactly: sqlite3_column_int64(statement, index))
    }

    // MARK: Duration 与毫秒互转

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    static func duration(milliseconds: Double) -> Duration {
        .nanoseconds(Int64((milliseconds * 1_000_000).rounded()))
    }
}
