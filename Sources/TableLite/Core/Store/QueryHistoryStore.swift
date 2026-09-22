import Foundation

/// 查询历史仓库（SQLite）。
///
/// 决策见 `02-persistence.md` §4：
/// - 存 `history.sqlite3`，用系统 `libsqlite3`，开启 WAL；
/// - **只记录来自 SQL 编辑器的语句**（由上层决定是否调用 `append`）；
/// - 默认保留最近 5000 条，超出按时间删除；
/// - 「清空历史」按连接删除，`clearAll()` 供 `⌥` 版本使用。
public actor QueryHistoryStore {

    /// 默认保留条数（`specs/11-preferences.md` §? / `02-persistence.md` §4）。
    public static let defaultRetention = 5000

    /// 当前 schema 版本（`02-persistence.md` §9：SQLite 用 `PRAGMA user_version`）。
    public static let schemaVersion: Int32 = 1

    private let layout: AppStorageLayout
    private let retention: Int
    private var database: SQLiteDatabase?

    public init(layout: AppStorageLayout, retention: Int = QueryHistoryStore.defaultRetention) {
        self.layout = layout
        self.retention = max(1, retention)
    }

    // MARK: - 打开

    private func openIfNeeded() throws -> SQLiteDatabase {
        if let database { return database }

        do {
            try AtomicFileWriter.ensureDirectory(layout.rootDirectory)
        } catch {
            StoreLog.error("创建查询历史目录失败：\(error)")
            throw error
        }

        let database = try SQLiteDatabase(path: layout.historyDatabase.path)

        // `02-persistence.md` §9：不认识的版本备份后重建。必须先读版本再写 schema，
        // 否则 `PRAGMA user_version` 会把未来版本号覆盖掉。
        let existingVersion = database.userVersion
        if existingVersion > Self.schemaVersion {
            database.close()
            let backup = layout.historyDatabase.appendingPathExtension("bak-\(existingVersion)")
            do {
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.moveItem(at: layout.historyDatabase, to: backup)
                StoreLog.warning("查询历史版本 \(existingVersion) 无法识别，已备份为 \(backup.lastPathComponent) 并重建。")
            } catch {
                StoreLog.error("备份查询历史失败：\(error)")
            }
            let rebuilt = try SQLiteDatabase(path: layout.historyDatabase.path)
            try createSchema(on: rebuilt)
            self.database = rebuilt
            return rebuilt
        }

        try createSchema(on: database)
        self.database = database
        return database
    }

    private func createSchema(on database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS query_history (
                id                 INTEGER PRIMARY KEY AUTOINCREMENT,
                connection_id      TEXT    NOT NULL,
                database_name      TEXT,
                sql                TEXT    NOT NULL,
                executed_at        REAL    NOT NULL,
                succeeded          INTEGER NOT NULL,
                duration_ms        INTEGER NOT NULL,
                returned_row_count INTEGER,
                affected_rows      INTEGER,
                error_code         INTEGER,
                error_message      TEXT
            );
            """)
        try database.execute("""
            CREATE INDEX IF NOT EXISTS idx_query_history_conn_time
            ON query_history (connection_id, executed_at DESC);
            """)
        try database.execute("""
            CREATE INDEX IF NOT EXISTS idx_query_history_time
            ON query_history (executed_at DESC);
            """)
        try database.execute("PRAGMA user_version = \(Self.schemaVersion);")
    }

    // MARK: - 写入

    /// 记录一条历史，返回带数据库自增 id 的副本；写完后按容量策略裁剪。
    @discardableResult
    public func append(_ entry: QueryHistoryEntry) throws -> QueryHistoryEntry {
        let database = try openIfNeeded()
        let statement = try database.prepare("""
            INSERT INTO query_history
                (connection_id, database_name, sql, executed_at, succeeded, duration_ms,
                 returned_row_count, affected_rows, error_code, error_message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        try statement.bind([
            .text(entry.connectionID.uuidString.lowercased()),
            entry.database.map { SQLiteValue.text($0) } ?? .null,
            .text(entry.sql),
            .double(entry.executedAt.timeIntervalSince1970),
            .int(entry.succeeded ? 1 : 0),
            .int(Int64(entry.durationMilliseconds)),
            entry.returnedRowCount.map { SQLiteValue.int(Int64($0)) } ?? .null,
            entry.affectedRows.map { SQLiteValue.int(Int64($0)) } ?? .null,
            entry.errorCode.map { SQLiteValue.int(Int64($0)) } ?? .null,
            entry.errorMessage.map { SQLiteValue.text($0) } ?? .null,
        ])
        _ = try statement.step()

        var stored = entry
        stored.id = database.lastInsertRowID
        try pruneIfNeeded(on: database, currentCount: try count(connectionID: nil, on: database))
        return stored
    }

    // MARK: - 查询

    /// 按条件查询历史，按时间倒序。
    ///
    /// - Parameters:
    ///   - connectionID: `nil` 表示全部连接（历史标签按连接过滤时传值）。
    ///   - search: SQL 内容子串搜索。
    ///   - limit / offset: 分页。
    ///   - since / until: 时间范围。
    public func recent(
        connectionID: UUID? = nil,
        search: String? = nil,
        limit: Int = 200,
        offset: Int = 0,
        since: Date? = nil,
        until: Date? = nil
    ) throws -> [QueryHistoryEntry] {
        let database = try openIfNeeded()

        var clauses: [String] = []
        var values: [SQLiteValue] = []

        if let connectionID {
            clauses.append("connection_id = ?")
            values.append(.text(connectionID.uuidString.lowercased()))
        }
        if let search, !search.isEmpty {
            clauses.append("sql LIKE ? ESCAPE '\\'")
            values.append(.text("%\(Self.escapeLike(search))%"))
        }
        if let since {
            clauses.append("executed_at >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        if let until {
            clauses.append("executed_at <= ?")
            values.append(.double(until.timeIntervalSince1970))
        }

        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let statement = try database.prepare("""
            SELECT id, connection_id, database_name, sql, executed_at, succeeded,
                   duration_ms, returned_row_count, affected_rows, error_code, error_message
            FROM query_history
            \(whereClause)
            ORDER BY executed_at DESC, id DESC
            LIMIT ? OFFSET ?;
            """)
        values.append(.int(Int64(max(0, limit))))
        values.append(.int(Int64(max(0, offset))))
        try statement.bind(values)

        var entries: [QueryHistoryEntry] = []
        while try statement.step() {
            entries.append(Self.entry(from: statement))
        }
        return entries
    }

    /// 统计条数。
    public func count(connectionID: UUID? = nil) throws -> Int {
        try count(connectionID: connectionID, on: openIfNeeded())
    }

    private func count(connectionID: UUID?, on database: SQLiteDatabase) throws -> Int {
        let sql: String
        let values: [SQLiteValue]
        if let connectionID {
            sql = "SELECT COUNT(*) FROM query_history WHERE connection_id = ?;"
            values = [.text(connectionID.uuidString.lowercased())]
        } else {
            sql = "SELECT COUNT(*) FROM query_history;"
            values = []
        }
        let statement = try database.prepare(sql)
        try statement.bind(values)
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    // MARK: - 删除

    /// 删除单条。
    public func delete(id: Int64) throws {
        let database = try openIfNeeded()
        let statement = try database.prepare("DELETE FROM query_history WHERE id = ?;")
        try statement.bind([.int(id)])
        _ = try statement.step()
    }

    /// 清空某个连接的历史（「清空历史」按钮）。
    public func clear(connectionID: UUID) throws {
        let database = try openIfNeeded()
        let statement = try database.prepare("DELETE FROM query_history WHERE connection_id = ?;")
        try statement.bind([.text(connectionID.uuidString.lowercased())])
        _ = try statement.step()
    }

    /// 清空全部连接的历史（`⌥` 点击「清空历史」）。
    public func clearAll() throws {
        let database = try openIfNeeded()
        try database.execute("DELETE FROM query_history;")
    }

    /// 按容量策略裁剪：保留最近 `retention` 条，其余按时间删除。
    public func prune() throws {
        let database = try openIfNeeded()
        try pruneIfNeeded(on: database, currentCount: try count(connectionID: nil, on: database))
    }

    private func pruneIfNeeded(on database: SQLiteDatabase, currentCount: Int) throws {
        guard currentCount > retention else { return }
        let statement = try database.prepare("""
            DELETE FROM query_history WHERE id NOT IN (
                SELECT id FROM query_history ORDER BY executed_at DESC, id DESC LIMIT ?
            );
            """)
        try statement.bind([.int(Int64(retention))])
        _ = try statement.step()
    }

    /// 关闭数据库句柄（退出时调用）。
    public func close() {
        database?.close()
        database = nil
    }

    // MARK: - 辅助

    private static func escapeLike(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\", "%", "_":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    private static func entry(from statement: SQLiteStatement) -> QueryHistoryEntry {
        let connectionText = statement.text(1) ?? ""
        let connectionID: UUID
        if let parsed = UUID(uuidString: connectionText) {
            connectionID = parsed
        } else {
            StoreLog.warning("查询历史里的连接 id 无法解析：\(connectionText)")
            connectionID = UUID()
        }
        return QueryHistoryEntry(
            id: statement.int64(0),
            connectionID: connectionID,
            database: statement.text(2),
            sql: statement.text(3) ?? "",
            executedAt: Date(timeIntervalSince1970: statement.double(4)),
            succeeded: statement.int(5) != 0,
            durationMilliseconds: statement.int(6),
            returnedRowCount: statement.isNull(7) ? nil : statement.int(7),
            affectedRows: statement.isNull(8) ? nil : statement.int(8),
            errorCode: statement.isNull(9) ? nil : UInt32(statement.int(9)),
            errorMessage: statement.text(10)
        )
    }
}
