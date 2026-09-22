import Foundation

/// `information_schema` 行 → `Core/Model` 模型的**纯函数映射**。
///
/// 决策见 `docs/tech-designs/11-schema-and-import-export.md` §1：
/// - 展示类型以 `COLUMN_TYPE` 原文为准；
/// - `COLUMN_KEY` / `EXTRA` / `IS_NULLABLE` 映射到 `ColumnInfo.flags`，让表结构列与结果集列
///   走同一套派生属性（`isPrimaryKey` / `isAutoIncrement` / `isUniqueKey` …）。
///
/// 不依赖数据库连接，全部可单测。
public enum MetaMapping {

    // MARK: 系统库

    /// 系统库名单（`specs/02-workspace.md` §4）。
    public static let systemDatabases: Set<String> = [
        "information_schema", "performance_schema", "mysql", "sys",
    ]

    /// 按偏好过滤系统库；`includeSystem == true` 时原样返回。
    public static func filterSystemDatabases(_ databases: [String], includeSystem: Bool) -> [String] {
        guard !includeSystem else { return databases }
        return databases.filter { !systemDatabases.contains($0.lowercased()) }
    }

    // MARK: 服务器信息

    /// `SELECT VERSION(), @@character_set_server, …` 的结果映射。
    public static func serverInfo(from rows: [MetaRow]) -> ServerInfo? {
        guard let row = rows.first else { return nil }
        return ServerInfo(
            version: row.text("version") ?? "",
            charset: row.text("server_charset") ?? "",
            collation: row.text("server_collation") ?? "",
            sqlMode: row.text("sql_mode") ?? "",
            connectionCharset: row.text("client_charset") ?? "",
            connectionCollation: row.text("connection_collation") ?? ""
        )
    }

    // MARK: 库列表

    /// `SHOW DATABASES` 的结果：只剩库名。
    public static func databaseNames(from rows: [MetaRow]) -> [String] {
        rows.compactMap { row in
            // `SHOW DATABASES` 列名是 `Database`（大小写随版本变化，MetaRow 已小写）。
            row.text("database") ?? row.text("schema_name")
        }
    }

    // MARK: 表 / 视图

    /// `information_schema.TABLES` 的结果映射成对象树里的表 / 视图。
    ///
    /// 只保留表与视图（S17）：`SYSTEM VIEW` 归为视图，其余非 `BASE TABLE` 一律丢弃。
    public static func tables(database: String, from rows: [MetaRow]) -> [TableInfo] {
        rows.compactMap { row in
            guard let name = row.text("table_name"), !name.isEmpty else { return nil }
            let type = (row.text("table_type") ?? "BASE TABLE").uppercased()
            let kind: TableKind
            if type.contains("VIEW") {
                // 系统视图不属于用户对象树。
                if type.contains("SYSTEM") { return nil }
                kind = .view
            } else if type == "BASE TABLE" {
                kind = .table
            } else {
                return nil
            }
            return TableInfo(
                database: database,
                name: name,
                kind: kind,
                engine: row.text("engine"),
                rowCountEstimate: row.int64("table_rows"),
                comment: row.text("table_comment"),
                collation: row.text("table_collation")
            )
        }
    }

    /// 行数估算。`TABLE_ROWS` 对 InnoDB 只是估算（L10），因此默认标注「约」。
    ///
    /// 取不到 `TABLE_ROWS` 时返回「估算不可靠」而不是 0。
    public static func rowCountEstimate(from rows: [MetaRow]) -> RowCountEstimate? {
        guard let row = rows.first else { return nil }
        guard let approximate = row.int64("table_rows") else {
            return RowCountEstimate(approximate: 0, isReliable: false, isExact: false)
        }
        return RowCountEstimate(approximate: approximate, isReliable: true, isExact: false)
    }

    // MARK: 列

    /// `information_schema.COLUMNS` 的结果映射成 `ColumnInfo`。
    public static func columns(from rows: [MetaRow]) -> [ColumnInfo] {
        rows.compactMap { row in
            guard let name = row.text("column_name"), !name.isEmpty else { return nil }
            let dataType = row.text("data_type")
            let columnType = row.text("column_type")
            let isNullable = row.bool("is_nullable") ?? true
            let columnKey = row.text("column_key")
            let extra = row.text("extra")
            let charsetName = row.text("character_set_name")
            let generationExpression = row.text("generation_expression")

            let fieldType = fieldType(forDataType: dataType)
            let isBinary = charsetName == nil && (dataType.map { isBinaryDataType($0) } ?? false)
            var flags = columnFlags(
                isNullable: isNullable,
                columnKey: columnKey,
                extra: extra,
                columnType: columnType,
                dataType: dataType,
                charsetName: charsetName,
                fieldType: fieldType
            )
            if isBinary { flags |= ColumnFlag.binary }

            let length = displayLength(columnType: columnType, dataType: dataType)
            let decimals = row.int("numeric_scale") ?? row.int("datetime_precision") ?? 0

            return ColumnInfo(
                name: name,
                originalName: name,
                originalTable: row.text("table_name"),
                database: row.text("table_schema"),
                fieldType: fieldType,
                flags: flags,
                charsetNumber: isBinary ? 63 : (fieldType.isStringType ? 33 : 0),
                length: length,
                decimals: decimals,
                dataType: dataType,
                columnTypeText: columnType,
                isNullable: isNullable,
                columnDefault: row.text("column_default"),
                hasDefaultValue: row.text("column_default") != nil,
                isGenerated: !(generationExpression ?? "").isEmpty
                    || (extra?.uppercased().contains("GENERATED") ?? false),
                generationExpression: generationExpression,
                comment: row.text("column_comment"),
                characterSet: charsetName,
                collation: row.text("collation_name"),
                ordinalPosition: row.int("ordinal_position"),
                extra: extra
            )
        }
        .sorted { ($0.ordinalPosition ?? 0) < ($1.ordinalPosition ?? 0) }
    }

    /// `DATA_TYPE` → `MySQLFieldType`。用于字面量生成与派生属性。
    public static func fieldType(forDataType dataType: String?) -> MySQLFieldType {
        switch dataType?.lowercased() {
        case "tinyint": return .tiny
        case "smallint": return .short
        case "mediumint": return .int24
        case "int", "integer": return .long
        case "bigint": return .longlong
        case "decimal", "numeric": return .newdecimal
        case "float": return .float
        case "double", "real": return .double
        case "bit": return .bit
        case "date": return .date
        case "datetime": return .datetime
        case "timestamp": return .timestamp
        case "time": return .time
        case "year": return .year
        case "char": return .string
        case "binary": return .string
        case "varchar", "varbinary": return .varString
        case "tinytext", "text", "mediumtext", "longtext",
             "tinyblob", "blob", "mediumblob", "longblob":
            return .blob
        case "json": return .json
        case "enum": return .enumeration
        case "set": return .set
        case "geometry", "point", "linestring", "polygon",
             "multipoint", "multilinestring", "multipolygon",
             "geometrycollection", "geomcollection":
            return .geometry
        default:
            return .varString
        }
    }

    /// 是否是二进制字符串类型（`CHARACTER_SET_NAME` 为 NULL）。
    public static func isBinaryDataType(_ dataType: String) -> Bool {
        switch dataType.lowercased() {
        case "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "geometry":
            return true
        default:
            return false
        }
    }

    /// `COLUMN_KEY` / `EXTRA` / `IS_NULLABLE` / `COLUMN_TYPE` → flags。
    static func columnFlags(
        isNullable: Bool,
        columnKey: String?,
        extra: String?,
        columnType: String?,
        dataType: String?,
        charsetName: String?,
        fieldType: MySQLFieldType
    ) -> UInt32 {
        var flags: UInt32 = 0
        if !isNullable { flags |= ColumnFlag.notNull }
        switch columnKey?.uppercased() {
        case "PRI":
            flags |= ColumnFlag.primaryKey
            flags |= ColumnFlag.notNull
        case "UNI":
            flags |= ColumnFlag.uniqueKey
        case "MUL":
            flags |= ColumnFlag.multipleKey
        default:
            break
        }
        let extraText = (extra ?? "").lowercased()
        if extraText.contains("auto_increment") { flags |= ColumnFlag.autoIncrement }
        if extraText.contains("on update current_timestamp") { flags |= ColumnFlag.onUpdateNow }
        let typeText = (columnType ?? "").lowercased()
        if typeText.contains("unsigned") { flags |= ColumnFlag.unsigned }
        if typeText.contains("zerofill") { flags |= ColumnFlag.zerofill }
        if fieldType == .enumeration { flags |= ColumnFlag.enumFlag }
        if fieldType == .set { flags |= ColumnFlag.set }
        if fieldType.isBlobType { flags |= ColumnFlag.blob }
        if charsetName == nil, let dataType, isBinaryDataType(dataType) { flags |= ColumnFlag.binary }
        return flags
    }

    /// 显示宽度：优先取 `COLUMN_TYPE` 里第一个括号数字（`tinyint(1)` / `decimal(10,2)`），
    /// 否则用 `CHARACTER_MAXIMUM_LENGTH` / `NUMERIC_PRECISION`。
    static func displayLength(columnType: String?, dataType: String?) -> Int {
        if let columnType, let open = columnType.firstIndex(of: "(") {
            let rest = columnType[columnType.index(after: open)...]
            let digits = rest.prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return 0
    }

    // MARK: 索引

    /// `information_schema.STATISTICS` 的结果按索引名分组。
    public static func indexes(from rows: [MetaRow]) -> [IndexInfo] {
        var order: [String] = []
        var groups: [String: [MetaRow]] = [:]
        for row in rows {
            guard let name = row.text("index_name") else { continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(row)
        }
        return order.compactMap { name in
            guard let group = groups[name] else { return nil }
            let sorted = group.sorted { ($0.int("seq_in_index") ?? 0) < ($1.int("seq_in_index") ?? 0) }
            let columns = sorted.map { row -> IndexColumn in
                var prefix = row.int("sub_part")
                if prefix == 0 { prefix = nil }
                let descending = (row.text("collation") ?? "").uppercased() == "D"
                return IndexColumn(
                    name: row.text("column_name") ?? "",
                    isDescending: descending,
                    prefixLength: prefix
                )
            }
            let first = sorted.first
            return IndexInfo(
                name: name,
                kind: indexKind(
                    name: name,
                    nonUnique: first?.bool("non_unique"),
                    indexType: first?.text("index_type")
                ),
                columns: columns,
                cardinality: first?.int64("cardinality"),
                comment: first?.text("index_comment")
            )
        }
    }

    static func indexKind(name: String, nonUnique: Bool?, indexType: String?) -> IndexKind {
        if name.uppercased() == "PRIMARY" { return .primary }
        switch indexType?.uppercased() {
        case "FULLTEXT": return .fulltext
        case "SPATIAL": return .spatial
        default: break
        }
        if nonUnique == false { return .unique }
        return .normal
    }

    // MARK: 外键

    /// `information_schema.KEY_COLUMN_USAGE` JOIN `REFERENTIAL_CONSTRAINTS` 的结果。
    public static func foreignKeys(from rows: [MetaRow]) -> [ForeignKeyInfo] {
        var order: [String] = []
        var groups: [String: [MetaRow]] = [:]
        for row in rows {
            guard let name = row.text("constraint_name") else { continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(row)
        }
        return order.compactMap { name in
            guard let group = groups[name] else { return nil }
            let sorted = group.sorted { ($0.int("ordinal_position") ?? 0) < ($1.int("ordinal_position") ?? 0) }
            let first = sorted.first
            guard let referencedTable = first?.text("referenced_table_name"), !referencedTable.isEmpty else {
                return nil
            }
            return ForeignKeyInfo(
                name: name,
                columns: sorted.map { $0.text("column_name") ?? "" },
                referencedDatabase: first?.text("referenced_table_schema"),
                referencedTable: referencedTable,
                referencedColumns: sorted.map { $0.text("referenced_column_name") ?? "" },
                onDelete: first?.text("delete_rule") ?? "NO ACTION",
                onUpdate: first?.text("update_rule") ?? "NO ACTION"
            )
        }
    }

    // MARK: 触发器

    /// `information_schema.TRIGGERS` 的结果。
    public static func triggers(from rows: [MetaRow]) -> [TriggerInfo] {
        rows.compactMap { row in
            guard let name = row.text("trigger_name") else { return nil }
            let timing = TriggerTiming(rawValue: (row.text("action_timing") ?? "").uppercased()) ?? .before
            let event = TriggerEvent(rawValue: (row.text("event_manipulation") ?? "").uppercased()) ?? .insert
            return TriggerInfo(
                name: name,
                timing: timing,
                event: event,
                statement: row.text("action_statement") ?? ""
            )
        }
    }

    // MARK: DDL 失效

    static let ddlKeywords: Set<String> = ["CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME"]
    static let ddlNoise: Set<String> = [
        "TEMPORARY", "IF", "NOT", "EXISTS", "ONLINE", "OFFLINE", "IGNORE", "ALGORITHM",
    ]

    /// 用词法扫描判断 SQL 是否含 DDL，并尽力解析出受影响的对象。
    ///
    /// 解析不确定时置 `unresolved`，调用方保守地失效整个库
    /// （`11-schema-and-import-export.md` §1.2）。
    public static func ddlInvalidation(in sql: String) -> DDLInvalidation {
        let tokens = SQLLexer.tokenize(sql).filter { $0.kind != .comment }
        guard tokens.contains(where: { isDDLKeyword($0) }) else {
            return DDLInvalidation(containsDDL: false)
        }

        var invalidation = DDLInvalidation(containsDDL: true)
        var index = 0
        while index < tokens.count {
            guard isDDLKeyword(tokens[index]) else {
                index += 1
                continue
            }
            index += 1

            // 跳过 TEMPORARY / IF NOT EXISTS / …
            while index < tokens.count,
                  tokens[index].kind == .keyword,
                  ddlNoise.contains(tokens[index].text.uppercased()) {
                index += 1
            }
            guard index < tokens.count else {
                invalidation.unresolved = true
                break
            }

            let ddlKeyword = tokens[index - 1].text.uppercased()
            var isDatabaseObject = false
            let objectWord = tokens[index].text.uppercased()
            if tokens[index].kind == .keyword,
               ["TABLE", "VIEW", "DATABASE", "SCHEMA"].contains(objectWord) {
                isDatabaseObject = objectWord == "DATABASE" || objectWord == "SCHEMA"
                index += 1
            } else if tokens[index].kind == .keyword, objectWord == "INDEX" {
                // CREATE / DROP INDEX … ON `table`
                var cursor = index
                while cursor < tokens.count, tokens[cursor].text.uppercased() != "ON" { cursor += 1 }
                guard cursor < tokens.count else {
                    invalidation.unresolved = true
                    continue
                }
                index = cursor + 1
            } else {
                // TRUNCATE 允许省略 TABLE；其余解析不出对象。
                if ddlKeyword != "TRUNCATE" {
                    invalidation.unresolved = true
                    continue
                }
            }

            // `TABLE IF NOT EXISTS` 这类噪声出现在对象关键字之后（`DROP TABLE IF EXISTS a, b`）。
            while index < tokens.count,
                  tokens[index].kind == .keyword,
                  ddlNoise.contains(tokens[index].text.uppercased()) {
                index += 1
            }

            var found = false
            while index < tokens.count {
                if tokens[index].kind == .punctuation, tokens[index].text == "," {
                    index += 1
                    continue
                }
                guard tokens[index].kind == .identifier || tokens[index].kind == .quotedIdentifier else { break }
                let first = normalizeIdentifier(tokens[index].text)
                index += 1
                if index + 1 < tokens.count,
                   tokens[index].kind == .punctuation, tokens[index].text == ".",
                   tokens[index + 1].kind == .identifier || tokens[index + 1].kind == .quotedIdentifier {
                    let second = normalizeIdentifier(tokens[index + 1].text)
                    if isDatabaseObject {
                        invalidation.databases.insert(first)
                    } else {
                        invalidation.tables.insert(TableRef(database: first, table: second))
                    }
                    index += 2
                } else if isDatabaseObject {
                    invalidation.databases.insert(first)
                } else {
                    invalidation.unqualifiedTables.insert(first)
                }
                found = true
                // RENAME TABLE a TO b：TO 之后的名字也要收集。
                if index < tokens.count, tokens[index].kind == .keyword,
                   tokens[index].text.uppercased() == "TO" {
                    index += 1
                    continue
                }
            }
            if !found { invalidation.unresolved = true }
        }
        return invalidation
    }

    static func isDDLKeyword(_ token: SQLToken) -> Bool {
        token.kind == .keyword && ddlKeywords.contains(token.text.uppercased())
    }

    static func normalizeIdentifier(_ text: String) -> String {
        var name = text
        if name.hasPrefix("`"), name.hasSuffix("`"), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return name.replacingOccurrences(of: "``", with: "`")
    }
}
