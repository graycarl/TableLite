import Foundation

/// `information_schema` 元数据仓库（每个 `ConnectionSession` 一个）。
///
/// 决策见 `docs/tech-designs/11-schema-and-import-export.md` §1：
/// - 全部走 `information_schema`（库列表用 `SHOW DATABASES`）；
/// - 缓存 TTL：库列表会话内不过期、对象列表 5 分钟、表结构 5 分钟、行数估算 30 秒；
/// - 失效入口：执行 DDL 后按解析出的对象失效，`⌘R` 调 `invalidateAll()`。
///
/// **缓存不跨连接共享**：它是 actor，由 `ConnectionSession` 独占持有。
public actor MetaRepository {

    // MARK: TTL

    /// 对象列表 TTL。
    public static let objectsTTL: TimeInterval = 5 * 60
    /// 表结构 TTL。
    public static let structureTTL: TimeInterval = 5 * 60
    /// 行数估算 TTL。
    public static let rowCountTTL: TimeInterval = 30

    // MARK: 内部

    private struct Timed<Value: Sendable>: Sendable {
        var value: Value
        var expiresAt: Date

        func isFresh(at now: Date) -> Bool { now < expiresAt }
    }

    private var session: any MySQLSessionProtocol
    private let clock: Clock
    private let log: @Sendable (QueryLogRecord) -> Void

    private var unfilteredDatabases: [String]?
    private var serverInfoCache: ServerInfo?
    private var objectsCache: [String: Timed<[TableInfo]>] = [:]
    private var structureCache: [String: Timed<TableStructure>] = [:]
    private var rowCountCache: [String: Timed<RowCountEstimate>] = [:]

    public init(
        session: any MySQLSessionProtocol,
        clock: Clock = SystemClock(),
        log: @escaping @Sendable (QueryLogRecord) -> Void = { _ in }
    ) {
        self.session = session
        self.clock = clock
        self.log = log
    }

    /// 换掉底层会话（重连后重建 `MySQLSession` 时用）；会清空全部缓存。
    public func updateSession(_ session: any MySQLSessionProtocol) {
        self.session = session
        invalidateAll()
    }

    // MARK: 库列表（会话内不过期）

    /// 全部库名（未过滤）。
    public func allDatabases(forceRefresh: Bool = false) async throws -> [String] {
        if !forceRefresh, let unfilteredDatabases { return unfilteredDatabases }
        let result = try await run("SHOW DATABASES")
        let names = MetaMapping.databaseNames(from: Self.rows(of: result))
        unfilteredDatabases = names
        return names
    }

    /// 按偏好过滤后的库名。
    public func databases(includeSystem: Bool) async throws -> [String] {
        let all = try await allDatabases()
        return MetaMapping.filterSystemDatabases(all, includeSystem: includeSystem)
    }

    // MARK: 对象列表（5 分钟）

    public func objects(database: String, forceRefresh: Bool = false) async throws -> [TableInfo] {
        let key = database.lowercased()
        if !forceRefresh, let cached = objectsCache[key], cached.isFresh(at: clock.now) {
            return cached.value
        }
        let sql = """
        SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, TABLE_COMMENT, TABLE_COLLATION
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(literal(database))
        ORDER BY TABLE_NAME
        """
        let result = try await run(sql, database: database)
        let tables = MetaMapping.tables(database: database, from: Self.rows(of: result))
        objectsCache[key] = Timed(value: tables, expiresAt: clock.now.addingTimeInterval(Self.objectsTTL))
        return tables
    }

    // MARK: 表结构（5 分钟）

    public func structure(
        database: String,
        table: String,
        kind: TableKind = .table,
        forceRefresh: Bool = false
    ) async throws -> TableStructure {
        let key = "\(database.lowercased()).\(table.lowercased())"
        if !forceRefresh, let cached = structureCache[key], cached.isFresh(at: clock.now) {
            return cached.value
        }

        let columnsSQL = """
        SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_DEFAULT, IS_NULLABLE,
               DATA_TYPE, COLUMN_TYPE, CHARACTER_SET_NAME, COLLATION_NAME, COLUMN_KEY, EXTRA,
               GENERATION_EXPRESSION, COLUMN_COMMENT, NUMERIC_SCALE, DATETIME_PRECISION
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = \(literal(database)) AND TABLE_NAME = \(literal(table))
        ORDER BY ORDINAL_POSITION
        """
        let indexesSQL = """
        SELECT INDEX_NAME, NON_UNIQUE, INDEX_TYPE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION, SUB_PART,
               CARDINALITY, INDEX_COMMENT
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = \(literal(database)) AND TABLE_NAME = \(literal(table))
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
        """
        let foreignKeysSQL = """
        SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.ORDINAL_POSITION, k.REFERENCED_TABLE_SCHEMA,
               k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
        FROM information_schema.KEY_COLUMN_USAGE AS k
        JOIN information_schema.REFERENTIAL_CONSTRAINTS AS r
          ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
         AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
         AND r.TABLE_NAME = k.TABLE_NAME
        WHERE k.TABLE_SCHEMA = \(literal(database)) AND k.TABLE_NAME = \(literal(table))
          AND k.REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
        """
        let triggersSQL = """
        SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT
        FROM information_schema.TRIGGERS
        WHERE EVENT_OBJECT_SCHEMA = \(literal(database)) AND EVENT_OBJECT_TABLE = \(literal(table))
        ORDER BY TRIGGER_NAME
        """

        let columnRows = try await run(columnsSQL, database: database)
        let indexRows = try await run(indexesSQL, database: database)
        let foreignKeyRows = try await run(foreignKeysSQL, database: database)
        let triggerRows = try await run(triggersSQL, database: database)

        // 表信息：如果对象列表已缓存，沿用它的行数估算与注释。
        // 对象类型以目录为准：视图结构用 `SHOW CREATE VIEW`，
        // 否则 `SHOW CREATE TABLE` 在视图上会失败（`specs/07-schema-view.md` §3）。
        let tableInfo = (try? await objects(database: database))?.first {
            $0.name == table
        } ?? TableInfo(database: database, name: table, kind: kind)
        let createStatement = try await fetchCreateStatement(
            database: database,
            table: table,
            kind: tableInfo.kind
        )

        let structure = TableStructure(
            table: tableInfo,
            columns: MetaMapping.columns(from: Self.rows(of: columnRows)),
            indexes: MetaMapping.indexes(from: Self.rows(of: indexRows)),
            foreignKeys: MetaMapping.foreignKeys(from: Self.rows(of: foreignKeyRows)),
            triggers: MetaMapping.triggers(from: Self.rows(of: triggerRows)),
            createStatement: createStatement
        )
        structureCache[key] = Timed(value: structure, expiresAt: clock.now.addingTimeInterval(Self.structureTTL))
        return structure
    }

    /// `SHOW CREATE TABLE` / `SHOW CREATE VIEW`。取第一个名字含 `Create` 的列。
    public func createStatement(database: String, table: String, kind: TableKind = .table) async throws -> String? {
        try await fetchCreateStatement(database: database, table: table, kind: kind)
    }

    private func fetchCreateStatement(database: String, table: String, kind: TableKind) async throws -> String? {
        let keyword = kind == .view ? "VIEW" : "TABLE"
        let sql = "SHOW CREATE \(keyword) \(SQLIdentifier.qualified(database: database, table: table))"
        let result = try await run(sql, database: database)
        guard let resultSet = result.firstResultSet else { return nil }
        let rows = Self.rows(of: result)
        guard let first = rows.first else { return nil }
        if let offset = resultSet.header.columns.firstIndex(where: { $0.name.lowercased().contains("create") }) {
            return first.values[offset]
        }
        // 兜底：取第二列。
        return first.values.count > 1 ? first.values[1] : nil
    }

    // MARK: 行数估算（30 秒）

    public func rowCountEstimate(
        database: String,
        table: String,
        forceRefresh: Bool = false
    ) async throws -> RowCountEstimate? {
        let key = "\(database.lowercased()).\(table.lowercased())"
        if !forceRefresh, let cached = rowCountCache[key], cached.isFresh(at: clock.now) {
            return cached.value
        }
        let sql = """
        SELECT TABLE_ROWS, TABLE_TYPE
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = \(literal(database)) AND TABLE_NAME = \(literal(table))
        LIMIT 1
        """
        let result = try await run(sql, database: database)
        guard let estimate = MetaMapping.rowCountEstimate(from: Self.rows(of: result)) else { return nil }
        rowCountCache[key] = Timed(value: estimate, expiresAt: clock.now.addingTimeInterval(Self.rowCountTTL))
        return estimate
    }

    // MARK: 服务器信息（会话内不过期）

    public func serverInfo(forceRefresh: Bool = false) async throws -> ServerInfo {
        if !forceRefresh, let serverInfoCache { return serverInfoCache }
        let sql = """
        SELECT VERSION() AS version,
               @@character_set_server AS server_charset,
               @@collation_server AS server_collation,
               @@sql_mode AS sql_mode,
               @@character_set_client AS client_charset,
               @@collation_connection AS connection_collation
        """
        let result = try await run(sql)
        guard let info = MetaMapping.serverInfo(from: Self.rows(of: result)) else {
            throw MetaRepositoryError.missingResult(sql)
        }
        serverInfoCache = info
        return info
    }

    // MARK: 失效

    /// 清空全部缓存（`⌘R` 手动刷新、重连）。
    public func invalidateAll() {
        unfilteredDatabases = nil
        serverInfoCache = nil
        objectsCache.removeAll()
        structureCache.removeAll()
        rowCountCache.removeAll()
    }

    /// 失效库列表，下次重新 `SHOW DATABASES`。
    public func invalidateDatabases() {
        unfilteredDatabases = nil
    }

    /// 失效某个库的对象列表。
    public func invalidateObjects(database: String) {
        objectsCache.removeValue(forKey: database.lowercased())
    }

    /// 失效单表结构 / 行数估算。
    public func invalidateTable(database: String, table: String) {
        let key = "\(database.lowercased()).\(table.lowercased())"
        structureCache.removeValue(forKey: key)
        rowCountCache.removeValue(forKey: key)
    }

    /// 执行 SQL 后按词法扫描的行结果失效缓存。
    ///
    /// - Parameter currentDatabase: 用于给只写了表名的 DDL 补上库名。
    /// - Returns: 解析结果，调用方据此刷新对象树、标记结构标签过期。
    @discardableResult
    public func noteExecutedSQL(_ sql: String, currentDatabase: String?) -> DDLInvalidation {
        let invalidation = MetaMapping.ddlInvalidation(in: sql)
        guard invalidation.containsDDL else { return invalidation }

        if invalidation.invalidatesWholeDatabase {
            objectsCache.removeAll()
            structureCache.removeAll()
            rowCountCache.removeAll()
            if !invalidation.databases.isEmpty { unfilteredDatabases = nil }
        } else {
            let refs = invalidation.resolvedTables(currentDatabase: currentDatabase)
            for ref in refs {
                invalidateTable(database: ref.database, table: ref.table)
                invalidateObjects(database: ref.database)
            }
            if refs.isEmpty {
                // 命中了 DDL 但一个对象都没解析出来：保守失效整个库。
                objectsCache.removeAll()
                structureCache.removeAll()
                rowCountCache.removeAll()
            }
        }
        return invalidation
    }

    // MARK: 私有

    /// 转义字符串字面量（用连接的转义器，兼容 `NO_BACKSLASH_ESCAPES`）。
    private func literal(_ value: String) -> String {
        SQLValueLiteral.quote(value, escaper: session.makeEscaper())
    }

    private func run(_ sql: String, database: String? = nil) async throws -> MySQLQueryResult {
        let started = clock.now
        do {
            let result = try await session.execute(sql, unbuffered: false)
            log(QueryLogRecord(
                tag: .meta,
                database: database,
                sql: sql,
                durationMilliseconds: Self.milliseconds(from: started, to: clock.now),
                returnedRowCount: result.rowCount,
                affectedRows: result.affectedRows,
                errorCode: result.firstError?.code,
                errorMessage: result.firstError?.message,
                isCancelled: result.wasCancelled
            ))
            return result
        } catch {
            let mysqlError = error as? MySQLError
            log(QueryLogRecord(
                tag: .meta,
                database: database,
                sql: sql,
                durationMilliseconds: Self.milliseconds(from: started, to: clock.now),
                errorCode: mysqlError?.code,
                errorMessage: mysqlError?.message ?? String(describing: error),
                isCancelled: mysqlError?.isCancellation ?? false
            ))
            throw error
        }
    }

    static func rows(of result: MySQLQueryResult) -> [MetaRow] {
        guard let resultSet = result.firstResultSet else { return [] }
        return MetaRow.rows(of: resultSet)
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }
}
