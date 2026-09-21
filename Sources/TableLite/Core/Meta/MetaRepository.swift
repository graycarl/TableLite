import Foundation

// MARK: - MetaRepository

/// 元数据读取与缓存（actor）。
///
/// 设计见 docs/tech-designs/11-schema-and-import-export.md §1：
/// - 数据来源是 `information_schema`（库列表用 `SHOW DATABASES`）；
/// - 缓存 TTL：库列表会话内不过期，对象列表 / 表结构 5 分钟，行数估算 30 秒；
/// - 执行 DDL 后用词法扫描失效对应缓存，解析不出目标时保守失效整个库。
///
/// 约束：
/// - 所有值都经 `SQLValueLiteral` + `session.literalizer()` 生成，标识符经 `SQLIdentifier.quote`，
///   不手工拼接字符串字面量（docs/tech-designs/03-mysql-layer.md §1）；
/// - 本层不写 Console Log，也不吞错误，`MySQLError` 原样向上抛。
///
/// 每个连接（`MySQLSession`）对应一个实例，缓存不跨连接共享
/// （docs/tech-designs/05-session-management.md §1）。
actor MetaRepository {

    /// 对象列表缓存 TTL。
    static let objectsTTL: TimeInterval = 5 * 60
    /// 表结构缓存 TTL。
    static let structureTTL: TimeInterval = 5 * 60
    /// 行数估算缓存 TTL。
    static let rowEstimateTTL: TimeInterval = 30

    private struct CacheEntry<Value> {
        var value: Value
        var loadedAt: Date
    }

    private let session: MySQLSession
    private let clock: Clock

    /// 库列表：会话内不过期，`invalidateAll()`（重连）时清空。
    private var databasesCache: [String]?
    private var objectsCache: [String: CacheEntry<[DatabaseObject]>] = [:]
    private var structureCache: [TableRef: CacheEntry<TableStructure>] = [:]
    private var rowEstimateCache: [TableRef: CacheEntry<UInt64?>] = [:]

    /// 最近一次读元数据涉及的库。DDL 解析不出库名时用它做保守失效。
    private var activeDatabase: String?

    init(session: MySQLSession, clock: Clock) {
        self.session = session
        self.clock = clock
    }

    // MARK: 库列表

    /// `SHOW DATABASES`，客户端过滤系统库（`MetaMapping.systemDatabases`）。
    func databases(includeSystem: Bool) async throws -> [String] {
        let all: [String]
        if let cached = databasesCache {
            all = cached
        } else {
            let results = try await session.queryAll("SHOW DATABASES", unbuffered: false)
            all = MetaMapping.databaseNames(from: MaterializedResultSet.firstResultSet(in: results))
            databasesCache = all
        }
        guard !includeSystem else { return all }
        return all.filter { !MetaMapping.isSystemDatabase($0) }
    }

    // MARK: 对象列表

    /// `information_schema.TABLES`，只取 `BASE TABLE` / `VIEW`，按名字排序。
    func objects(database: String) async throws -> [DatabaseObject] {
        activeDatabase = database
        if let cached = objectsCache[database], isFresh(cached.loadedAt, ttl: Self.objectsTTL) {
            return cached.value
        }

        let literalizer = await session.literalizer()
        let sql = """
            SELECT TABLE_NAME, TABLE_TYPE, TABLE_ROWS, TABLE_COMMENT
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(textLiteral(database, using: literalizer))
              AND TABLE_TYPE IN (\(textLiteral("BASE TABLE", using: literalizer)), \(textLiteral("VIEW", using: literalizer)))
            ORDER BY TABLE_NAME
            """
        let results = try await session.queryAll(sql, unbuffered: false)
        let objects = MetaMapping.objects(from: MaterializedResultSet.firstResultSet(in: results))
        objectsCache[database] = CacheEntry(value: objects, loadedAt: clock.now)
        return objects
    }

    // MARK: 表结构

    /// 列 / 索引 / 外键 / 触发器 / 建表语句一次取全。
    ///
    /// 另加一次 `information_schema.TABLES` 查询取对象类型与表注释 —— `TableStructure`
    /// 需要 `kind` 与 `comment`，这是对接口契约的补充（不属于原定五部分）。
    func structure(_ ref: TableRef) async throws -> TableStructure {
        activeDatabase = ref.database
        if let cached = structureCache[ref], isFresh(cached.loadedAt, ttl: Self.structureTTL) {
            return cached.value
        }

        let literalizer = await session.literalizer()
        let database = textLiteral(ref.database, using: literalizer)
        let table = textLiteral(ref.table, using: literalizer)

        let columnsSQL = """
            SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE,
                   COLUMN_KEY, COLUMN_DEFAULT, EXTRA, CHARACTER_SET_NAME, COLLATION_NAME,
                   COLUMN_COMMENT, GENERATION_EXPRESSION
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(database) AND TABLE_NAME = \(table)
            ORDER BY ORDINAL_POSITION
            """
        let columnsResults = try await session.queryAll(columnsSQL, unbuffered: false)
        let columns = MetaMapping.columns(from: MaterializedResultSet.firstResultSet(in: columnsResults))

        let indexesSQL = """
            SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION,
                   CARDINALITY, INDEX_TYPE, INDEX_COMMENT
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(database) AND TABLE_NAME = \(table)
            ORDER BY INDEX_NAME, SEQ_IN_INDEX
            """
        let indexesResults = try await session.queryAll(indexesSQL, unbuffered: false)
        let indexes = MetaMapping.indexes(from: MaterializedResultSet.firstResultSet(in: indexesResults))

        let foreignKeysSQL = """
            SELECT kcu.CONSTRAINT_NAME, kcu.COLUMN_NAME, kcu.ORDINAL_POSITION,
                   kcu.REFERENCED_TABLE_SCHEMA, kcu.REFERENCED_TABLE_NAME, kcu.REFERENCED_COLUMN_NAME,
                   rc.DELETE_RULE, rc.UPDATE_RULE
            FROM information_schema.KEY_COLUMN_USAGE AS kcu
            JOIN information_schema.REFERENTIAL_CONSTRAINTS AS rc
              ON rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
             AND rc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
             AND rc.TABLE_NAME = kcu.TABLE_NAME
            WHERE kcu.TABLE_SCHEMA = \(database) AND kcu.TABLE_NAME = \(table)
              AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION
            """
        let foreignKeyResults = try await session.queryAll(foreignKeysSQL, unbuffered: false)
        let foreignKeys = MetaMapping.foreignKeys(from: MaterializedResultSet.firstResultSet(in: foreignKeyResults))

        let triggersSQL = """
            SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT
            FROM information_schema.TRIGGERS
            WHERE TRIGGER_SCHEMA = \(database) AND EVENT_OBJECT_TABLE = \(table)
            ORDER BY TRIGGER_NAME
            """
        let triggerResults = try await session.queryAll(triggersSQL, unbuffered: false)
        let triggers = MetaMapping.triggers(from: MaterializedResultSet.firstResultSet(in: triggerResults))

        // 表与视图都用 SHOW CREATE TABLE：视图返回 `Create View` 列
        let createResults = try await session.queryAll(
            "SHOW CREATE TABLE \(SQLIdentifier.qualified(ref.database, ref.table))",
            unbuffered: false
        )
        let create = MetaMapping.createStatement(from: MaterializedResultSet.firstResultSet(in: createResults))

        let infoSQL = """
            SELECT TABLE_TYPE, TABLE_COMMENT
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(database) AND TABLE_NAME = \(table)
            """
        let infoResults = try await session.queryAll(infoSQL, unbuffered: false)
        let info = MetaMapping.tableInfo(from: MaterializedResultSet.firstResultSet(in: infoResults))

        let structure = TableStructure(
            ref: ref,
            kind: create?.kind ?? info?.kind ?? .table,
            comment: info?.comment,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            triggers: triggers,
            createStatement: create?.sql ?? ""
        )
        structureCache[ref] = CacheEntry(value: structure, loadedAt: clock.now)
        return structure
    }

    // MARK: 行数

    /// `information_schema.TABLES.TABLE_ROWS` 估算。视图 / 无权限返回 nil。
    func rowEstimate(_ ref: TableRef) async throws -> UInt64? {
        activeDatabase = ref.database
        if let cached = rowEstimateCache[ref], isFresh(cached.loadedAt, ttl: Self.rowEstimateTTL) {
            return cached.value
        }

        let literalizer = await session.literalizer()
        let sql = """
            SELECT TABLE_ROWS
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(textLiteral(ref.database, using: literalizer))
              AND TABLE_NAME = \(textLiteral(ref.table, using: literalizer))
            """
        let results = try await session.queryAll(sql, unbuffered: false)
        let estimate = MetaMapping.rowEstimate(from: MaterializedResultSet.firstResultSet(in: results))
        rowEstimateCache[ref] = CacheEntry(value: estimate, loadedAt: clock.now)
        return estimate
    }

    /// 精确 `COUNT(*)`，`whereClause` 由调用方（过滤器生成器）拼好。
    func preciseCount(_ ref: TableRef, whereClause: String?) async throws -> UInt64 {
        var sql = "SELECT COUNT(*) AS `count` FROM \(SQLIdentifier.qualified(ref.database, ref.table))"
        if let whereClause, !whereClause.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sql += " WHERE \(whereClause)"
        }
        let results = try await session.queryAll(sql, unbuffered: false)
        guard let value = MaterializedResultSet.firstResultSet(in: results)?.rows.first?.first,
              !value.isNull,
              let count = UInt64(value.displayText) else {
            throw MySQLError.internalError("COUNT(*) 未返回可解析的行数")
        }
        return count
    }

    // MARK: 缓存失效

    /// 执行 SQL 后调用。词法扫描出 DDL 即失效对应缓存；解析不出目标时保守失效整个库。
    func noteExecutedSQL(_ sql: String) {
        let invalidation = MetaMapping.ddlInvalidation(in: sql)
        guard invalidation.containsDDL else { return }

        var refs = Set(invalidation.tables)
        var wholeDatabases = Set<String>()

        for name in invalidation.unqualifiedTables {
            if let database = activeDatabase {
                refs.insert(TableRef(database: database, table: name))
            } else {
                // 没有库上下文：把所有缓存里同名的表都失效
                for ref in structureCache.keys where ref.table == name {
                    refs.insert(ref)
                }
            }
        }

        if invalidation.unresolved {
            if let database = activeDatabase {
                wholeDatabases.insert(database)
            } else {
                invalidateAll()
                return
            }
        }

        if !invalidation.databases.isEmpty {
            // CREATE / DROP DATABASE 会改变库列表
            databasesCache = nil
            wholeDatabases.formUnion(invalidation.databases)
        }

        for ref in refs { invalidate(ref) }
        for database in wholeDatabases { invalidateDatabase(database) }
    }

    func invalidate(_ ref: TableRef) {
        structureCache[ref] = nil
        rowEstimateCache[ref] = nil
        // 对象列表可能因 DROP / RENAME / CREATE 变化，一并失效
        objectsCache[ref.database] = nil
    }

    func invalidateDatabase(_ database: String) {
        objectsCache[database] = nil
        structureCache = structureCache.filter { $0.key.database != database }
        rowEstimateCache = rowEstimateCache.filter { $0.key.database != database }
    }

    func invalidateAll() {
        databasesCache = nil
        objectsCache.removeAll()
        structureCache.removeAll()
        rowEstimateCache.removeAll()
        activeDatabase = nil
    }

    // MARK: 内部

    private func isFresh(_ loadedAt: Date, ttl: TimeInterval) -> Bool {
        clock.now.timeIntervalSince(loadedAt) < ttl
    }

    private func textLiteral(_ value: String, using literalizer: SQLValueLiteralizer) -> String {
        SQLValueLiteral.literal(CellValue.text(value), kind: .text, using: literalizer)
    }
}
