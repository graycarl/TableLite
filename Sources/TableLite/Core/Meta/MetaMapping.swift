import Foundation

// MARK: - 元数据映射（纯函数）
//
// `information_schema` 查询结果 → Core 模型，以及执行 SQL 后的 DDL 缓存失效判定。
// 这里只做纯解析，不碰 `MySQLSession`、不读时钟，便于单元测试覆盖。
// 见 docs/tech-designs/11-schema-and-import-export.md §1。
enum MetaMapping {

    // MARK: 系统库

    /// 客户端过滤名单。见 docs/tech-designs/11-schema-and-import-export.md §1.2。
    static let systemDatabases: Set<String> = [
        "information_schema", "performance_schema", "mysql", "sys",
    ]

    static func isSystemDatabase(_ name: String) -> Bool {
        systemDatabases.contains(name.lowercased())
    }

    // MARK: 库列表（SHOW DATABASES）

    /// `SHOW DATABASES` 返回一列（名为 `Database`），只取第一列。
    static func databaseNames(from resultSet: MaterializedResultSet?) -> [String] {
        guard let resultSet else { return [] }
        return resultSet.rows.compactMap { row in
            guard let first = row.first, !first.isNull else { return nil }
            let name = first.displayText
            return name.isEmpty ? nil : name
        }
    }

    // MARK: 对象列表（information_schema.TABLES）

    static func objects(from resultSet: MaterializedResultSet?) -> [DatabaseObject] {
        guard let resultSet else { return [] }
        let objects = resultSet.readers.compactMap { reader -> DatabaseObject? in
            guard let name = reader.nonEmptyString("TABLE_NAME") else { return nil }
            let kind = objectKind(fromTableType: reader.string("TABLE_TYPE"))
            return DatabaseObject(
                name: name,
                kind: kind,
                // 视图没有行数估算
                rowEstimate: kind == .table ? reader.uint64("TABLE_ROWS") : nil,
                comment: objectComment(reader.string("TABLE_COMMENT"), kind: kind)
            )
        }
        // MySQL 按排序规则返回，客户端再按字节序兜底，保证结果稳定
        return objects.sorted { $0.name < $1.name }
    }

    static func objectKind(fromTableType tableType: String?) -> DatabaseObjectKind {
        (tableType ?? "").uppercased().contains("VIEW") ? .view : .table
    }

    /// 空注释归一为 nil；MySQL 给视图的 `TABLE_COMMENT` 固定是 `VIEW`，不是用户注释。
    static func objectComment(_ raw: String?, kind: DatabaseObjectKind) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if kind == .view, raw.uppercased() == "VIEW" { return nil }
        return raw
    }

    struct TableInfo: Equatable, Sendable {
        var kind: DatabaseObjectKind
        var comment: String?
    }

    static func tableInfo(from resultSet: MaterializedResultSet?) -> TableInfo? {
        guard let reader = resultSet?.readers.first else { return nil }
        let kind = objectKind(fromTableType: reader.string("TABLE_TYPE"))
        return TableInfo(kind: kind, comment: objectComment(reader.string("TABLE_COMMENT"), kind: kind))
    }

    static func rowEstimate(from resultSet: MaterializedResultSet?) -> UInt64? {
        guard let reader = resultSet?.readers.first else { return nil }
        return reader.uint64("TABLE_ROWS")
    }

    // MARK: 列（information_schema.COLUMNS）

    static func columns(from resultSet: MaterializedResultSet?) -> [TableColumn] {
        guard let resultSet else { return [] }
        return resultSet.readers
            .compactMap { tableColumn(from: $0) }
            .sorted { $0.position < $1.position }
    }

    static func tableColumn(from reader: ResultRowReader) -> TableColumn? {
        guard let name = reader.nonEmptyString("COLUMN_NAME"),
              let dataType = reader.nonEmptyString("DATA_TYPE") else { return nil }

        let rawTypeText = reader.string("COLUMN_TYPE") ?? dataType
        let isNullable = reader.bool("IS_NULLABLE") ?? true
        let extraTokens = tokens(reader.string("EXTRA"))
        let isGenerated = extraTokens.contains("GENERATED")
        let isInvisible = extraTokens.contains("INVISIBLE")
        let isAutoIncrement = extraTokens.contains("AUTO_INCREMENT")
        let isUnsigned = rawTypeText.lowercased().contains("unsigned")
        let kind = ColumnKindClassifier.kind(dataType: dataType, rawTypeText: rawTypeText)
        let charset = reader.nonEmptyString("CHARACTER_SET_NAME")
        let collation = reader.nonEmptyString("COLLATION_NAME")
        let enumValues = (kind == .enumType || kind == .setType)
            ? ColumnKindClassifier.enumValues(rawTypeText: rawTypeText)
            : nil

        return TableColumn(
            name: name,
            position: reader.int("ORDINAL_POSITION") ?? 0,
            dataType: dataType,
            rawTypeText: rawTypeText,
            isNullable: isNullable,
            isPrimaryKey: reader.string("COLUMN_KEY")?.uppercased() == "PRI",
            isAutoIncrement: isAutoIncrement,
            isUnsigned: isUnsigned,
            isBinary: isBinaryColumn(dataType: dataType, kind: kind, charset: charset),
            isGenerated: isGenerated,
            isInvisible: isInvisible,
            charset: charset,
            collation: collation,
            defaultValue: isGenerated ? nil : defaultLiteral(reader.value("COLUMN_DEFAULT"), isNullable: isNullable),
            comment: reader.nonEmptyString("COLUMN_COMMENT"),
            kind: kind,
            enumValues: enumValues
        )
    }

    /// `COLUMN_DEFAULT` 的显示语义。见 specs/07-schema-view.md §2.1：
    /// 没有默认值 → nil（界面显示 `—`）；默认值为 NULL → `"NULL"`。
    ///
    /// `information_schema` 对「没有 DEFAULT 子句」与「DEFAULT NULL」都返回 SQL NULL，
    /// 无法区分；可空列本来就有隐式 NULL 默认，因此按 NULL 展示，非空列才算没有默认值。
    static func defaultLiteral(_ value: CellValue?, isNullable: Bool) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return isNullable ? "NULL" : nil
        case .bytes:
            return value.displayText
        }
    }

    static func isBinaryColumn(dataType: String, kind: ColumnKind, charset: String?) -> Bool {
        if kind.isBinaryLike { return true }
        switch dataType.lowercased() {
        case "binary", "varbinary":
            return true
        default:
            return charset?.lowercased() == "binary"
        }
    }

    // MARK: 索引（information_schema.STATISTICS）

    static func indexes(from resultSet: MaterializedResultSet?) -> [TableIndex] {
        guard let resultSet else { return [] }

        var order: [String] = []
        var columnsByName: [String: [IndexColumn]] = [:]
        var nonUniqueByName: [String: Bool] = [:]
        var rawTypeByName: [String: String] = [:]
        var cardinalityByName: [String: UInt64] = [:]
        var commentByName: [String: String] = [:]

        for reader in resultSet.readers {
            guard let name = reader.nonEmptyString("INDEX_NAME") else { continue }
            if columnsByName[name] == nil {
                order.append(name)
                columnsByName[name] = []
                nonUniqueByName[name] = (reader.int("NON_UNIQUE") ?? 1) != 0
                rawTypeByName[name] = reader.string("INDEX_TYPE") ?? ""
                cardinalityByName[name] = 0
                commentByName[name] = reader.nonEmptyString("INDEX_COMMENT")
            }
            let descending = reader.string("COLLATION")?.uppercased() == "D"
            columnsByName[name]?.append(
                IndexColumn(name: reader.string("COLUMN_NAME") ?? "", descending: descending)
            )
            if let cardinality = reader.uint64("CARDINALITY") {
                cardinalityByName[name] = max(cardinalityByName[name] ?? 0, cardinality)
            }
            if commentByName[name] == nil, let comment = reader.nonEmptyString("INDEX_COMMENT") {
                commentByName[name] = comment
            }
        }

        let indexes = order.map { name -> TableIndex in
            let cardinality: UInt64? = (cardinalityByName[name] ?? 0) > 0 ? cardinalityByName[name] : nil
            return TableIndex(
                name: name,
                indexType: indexDisplayType(
                    name: name,
                    nonUnique: nonUniqueByName[name] ?? true,
                    rawIndexType: rawTypeByName[name] ?? ""
                ),
                columns: columnsByName[name] ?? [],
                cardinality: cardinality,
                comment: commentByName[name]
            )
        }
        // PRIMARY 放最前，其余按名字排序，保证结果稳定
        return indexes.sorted { lhs, rhs in
            let leftPrimary = lhs.indexType == "PRIMARY" ? 0 : 1
            let rightPrimary = rhs.indexType == "PRIMARY" ? 0 : 1
            if leftPrimary != rightPrimary { return leftPrimary < rightPrimary }
            return lhs.name < rhs.name
        }
    }

    /// 归一到 `TableIndex.indexType` 的五种取值：PRIMARY / UNIQUE / FULLTEXT / SPATIAL / INDEX。
    static func indexDisplayType(name: String, nonUnique: Bool, rawIndexType: String) -> String {
        let raw = rawIndexType.uppercased()
        if raw == "FULLTEXT" { return "FULLTEXT" }
        if raw == "SPATIAL" { return "SPATIAL" }
        if name.uppercased() == "PRIMARY" { return "PRIMARY" }
        if !nonUnique { return "UNIQUE" }
        return "INDEX"
    }

    // MARK: 外键（KEY_COLUMN_USAGE ⋈ REFERENTIAL_CONSTRAINTS）

    static func foreignKeys(from resultSet: MaterializedResultSet?) -> [ForeignKeyConstraint] {
        guard let resultSet else { return [] }

        var order: [String] = []
        var columnsByName: [String: [String]] = [:]
        var referencedColumnsByName: [String: [String]] = [:]
        var referencedDatabaseByName: [String: String] = [:]
        var referencedTableByName: [String: String] = [:]
        var onDeleteByName: [String: String] = [:]
        var onUpdateByName: [String: String] = [:]

        for reader in resultSet.readers {
            guard let name = reader.nonEmptyString("CONSTRAINT_NAME") else { continue }
            if columnsByName[name] == nil {
                order.append(name)
                columnsByName[name] = []
                referencedColumnsByName[name] = []
                referencedDatabaseByName[name] = reader.string("REFERENCED_TABLE_SCHEMA") ?? ""
                referencedTableByName[name] = reader.string("REFERENCED_TABLE_NAME") ?? ""
                onDeleteByName[name] = reader.string("DELETE_RULE") ?? "NO ACTION"
                onUpdateByName[name] = reader.string("UPDATE_RULE") ?? "NO ACTION"
            }
            columnsByName[name]?.append(reader.string("COLUMN_NAME") ?? "")
            referencedColumnsByName[name]?.append(reader.string("REFERENCED_COLUMN_NAME") ?? "")
        }

        return order.map { name in
            ForeignKeyConstraint(
                name: name,
                columns: columnsByName[name] ?? [],
                referencedDatabase: referencedDatabaseByName[name] ?? "",
                referencedTable: referencedTableByName[name] ?? "",
                referencedColumns: referencedColumnsByName[name] ?? [],
                onDelete: onDeleteByName[name] ?? "NO ACTION",
                onUpdate: onUpdateByName[name] ?? "NO ACTION"
            )
        }
    }

    // MARK: 触发器（information_schema.TRIGGERS）

    static func triggers(from resultSet: MaterializedResultSet?) -> [TableTrigger] {
        guard let resultSet else { return [] }
        return resultSet.readers.compactMap { reader -> TableTrigger? in
            guard let name = reader.nonEmptyString("TRIGGER_NAME") else { return nil }
            return TableTrigger(
                name: name,
                timing: reader.string("ACTION_TIMING") ?? "",
                event: reader.string("EVENT_MANIPULATION") ?? "",
                statement: reader.string("ACTION_STATEMENT") ?? ""
            )
        }
    }

    // MARK: 建表语句（SHOW CREATE TABLE / SHOW CREATE VIEW）

    struct CreateStatement: Equatable, Sendable {
        var kind: DatabaseObjectKind
        var sql: String
    }

    /// 取列名以 `Create ` 开头的列（`Create Table` / `Create View`），并据此判断对象类型。
    static func createStatement(from resultSet: MaterializedResultSet?) -> CreateStatement? {
        guard let resultSet,
              let index = resultSet.header.columns.firstIndex(where: {
                  $0.name.lowercased().hasPrefix("create ")
              }),
              let row = resultSet.rows.first,
              index < row.count,
              !row[index].isNull else { return nil }

        let columnName = resultSet.header.columns[index].name.lowercased()
        return CreateStatement(
            kind: columnName.contains("view") ? .view : .table,
            sql: row[index].displayText
        )
    }

    // MARK: - DDL 失效判定
    //
    // 执行 SQL 后用词法扫描判断是否包含会改结构的 DDL；命中则失效对应表缓存，
    // 解析不出目标时保守失效整个库。见 docs/tech-designs/11-schema-and-import-export.md §1.2。

    /// 一次 SQL 执行对元数据缓存的影响。库名交给调用方结合「当前库」补全。
    struct DDLInvalidation: Equatable, Sendable {
        /// 已带库名的表
        var tables: [TableRef] = []
        /// 只有表名、没有库名
        var unqualifiedTables: [String] = []
        /// 明确针对的库（CREATE / DROP DATABASE 等）
        var databases: [String] = []
        /// 命中了 DDL 但无法定位对象 → 保守失效
        var unresolved: Bool = false
        /// 是否包含 DDL
        var containsDDL: Bool = false
    }

    /// 需要关注的 DDL 对象关键字。
    private static let ddlObjectKeywords: Set<String> = [
        "TABLE", "VIEW", "INDEX", "TRIGGER", "DATABASE", "SCHEMA",
    ]

    static func ddlInvalidation(in sql: String) -> DDLInvalidation {
        var result = DDLInvalidation()
        for statement in StatementSplitter.split(sql) where isStructureDDL(statement) {
            result.containsDDL = true
            parseDDL(statement.text, into: &result)
        }
        return result
    }

    /// 是否是需要失效元数据的 DDL。
    ///
    /// 先用 `StatementSplitter` 拆句，再用 `ReadOnlyGuard` 的词法判定把只读白名单里的
    /// 语句排除；只有 `CREATE / ALTER / DROP / TRUNCATE / RENAME` 会被拆成 `.ddl`。
    private static func isStructureDDL(_ statement: SQLStatement) -> Bool {
        guard statement.kind == .ddl else { return false }
        if case .allowed = ReadOnlyGuard.evaluate(statement) { return false }
        return true
    }

    // MARK: DDL 解析内部

    private struct DDLToken {
        var kind: SQLTokenKind
        var text: String
        var upper: String
    }

    private static func ddlTokens(in text: String) -> [DDLToken] {
        SQLLexer.tokenize(text)
            .filter { $0.kind != .comment }
            .map { token in
                let raw = SQLLexer.text(of: token, in: text)
                return DDLToken(kind: token.kind, text: raw, upper: raw.uppercased())
            }
    }

    private static func parseDDL(_ text: String, into result: inout DDLInvalidation) {
        let tokens = ddlTokens(in: text)
        guard let leadIndex = tokens.firstIndex(where: { $0.kind == .keyword }) else { return }
        switch tokens[leadIndex].upper {
        case "TRUNCATE":
            parseTruncate(tokens, leadIndex: leadIndex, into: &result)
        case "RENAME":
            parseRename(tokens, leadIndex: leadIndex, into: &result)
        case "CREATE", "ALTER", "DROP":
            parseCreateAlterDrop(lead: tokens[leadIndex].upper, tokens, into: &result)
        default:
            break
        }
    }

    private static func parseCreateAlterDrop(lead: String, _ tokens: [DDLToken],
                                             into result: inout DDLInvalidation) {
        // 找到第一个目标对象关键字（跳过 OR REPLACE / TEMPORARY / ALGORITHM=... 等修饰）
        guard let objectIndex = tokens.firstIndex(where: {
            $0.kind == .keyword && ddlObjectKeywords.contains($0.upper)
        }) else { return }

        switch tokens[objectIndex].upper {
        case "DATABASE", "SCHEMA":
            if lead == "CREATE" || lead == "DROP" {
                let index = skippingIfClause(tokens, from: objectIndex + 1)
                if let name = nameToken(tokens, at: index) {
                    result.databases.append(name)
                } else {
                    result.unresolved = true
                }
            }
        case "TABLE":
            parseTableObject(lead: lead, tokens, objectIndex: objectIndex, into: &result)
        case "VIEW":
            parseViewObject(lead: lead, tokens, objectIndex: objectIndex, into: &result)
        case "INDEX":
            parseIndexObject(tokens, into: &result)
        case "TRIGGER":
            parseTriggerObject(lead: lead, tokens, into: &result)
        default:
            break
        }
    }

    private static func parseTableObject(lead: String, _ tokens: [DDLToken], objectIndex: Int,
                                         into result: inout DDLInvalidation) {
        var index = objectIndex + 1
        if isKeyword(tokens, index, "TEMPORARY") { index += 1 }
        index = skippingIfClause(tokens, from: index)

        switch lead {
        case "CREATE":
            append(parseQualifiedName(tokens, from: index), into: &result)
        case "ALTER":
            append(parseQualifiedName(tokens, from: index), into: &result)
            if let renameIndex = tokens.firstIndex(where: { $0.kind == .keyword && $0.upper == "RENAME" }),
               !isKeyword(tokens, renameIndex + 1, "COLUMN"),
               !isKeyword(tokens, renameIndex + 1, "INDEX"),
               !isKeyword(tokens, renameIndex + 1, "KEY"),
               !isKeyword(tokens, renameIndex + 1, "CONSTRAINT") {
                var target = renameIndex + 1
                if isKeyword(tokens, target, "TO") { target += 1 }
                append(parseQualifiedName(tokens, from: target), into: &result)
            }
        case "DROP":
            let names = parseNameList(tokens, from: index)
            if names.isEmpty { result.unresolved = true }
            for name in names { append(name, into: &result) }
        default:
            break
        }
    }

    private static func parseViewObject(lead: String, _ tokens: [DDLToken], objectIndex: Int,
                                        into result: inout DDLInvalidation) {
        let index = skippingIfClause(tokens, from: objectIndex + 1)
        switch lead {
        case "CREATE", "ALTER":
            append(parseQualifiedName(tokens, from: index), into: &result)
        case "DROP":
            let names = parseNameList(tokens, from: index)
            if names.isEmpty { result.unresolved = true }
            for name in names { append(name, into: &result) }
        default:
            break
        }
    }

    private static func parseIndexObject(_ tokens: [DDLToken], into result: inout DDLInvalidation) {
        // CREATE / DROP INDEX ... ON tbl
        guard let onIndex = tokens.firstIndex(where: { $0.kind == .keyword && $0.upper == "ON" }) else {
            result.unresolved = true
            return
        }
        append(parseQualifiedName(tokens, from: onIndex + 1), into: &result)
    }

    private static func parseTriggerObject(lead: String, _ tokens: [DDLToken],
                                           into result: inout DDLInvalidation) {
        // DROP TRIGGER 只知道触发器名，定位不到表 → 保守处理
        guard lead == "CREATE",
              let onIndex = tokens.firstIndex(where: { $0.kind == .keyword && $0.upper == "ON" }) else {
            result.unresolved = true
            return
        }
        append(parseQualifiedName(tokens, from: onIndex + 1), into: &result)
    }

    private static func parseTruncate(_ tokens: [DDLToken], leadIndex: Int,
                                      into result: inout DDLInvalidation) {
        var index = leadIndex + 1
        if isKeyword(tokens, index, "TABLE") { index += 1 }
        append(parseQualifiedName(tokens, from: index), into: &result)
    }

    private static func parseRename(_ tokens: [DDLToken], leadIndex: Int,
                                    into result: inout DDLInvalidation) {
        var index = leadIndex + 1
        if isKeyword(tokens, index, "TABLE") { index += 1 }

        var found = false
        while true {
            guard let source = parseQualifiedName(tokens, from: index) else { break }
            append(source, into: &result)
            found = true
            index = source.next

            if isKeyword(tokens, index, "TO") { index += 1 }
            guard let target = parseQualifiedName(tokens, from: index) else { break }
            append(target, into: &result)
            index = target.next

            if index < tokens.count, tokens[index].kind == .punctuation, tokens[index].text == "," {
                index += 1
                continue
            }
            break
        }
        if !found { result.unresolved = true }
    }

    // MARK: DDL 解析工具

    /// 表名位置允许出现的关键字（未加反引号的保留字也可能被当成名字）。
    private static func nameToken(_ tokens: [DDLToken], at index: Int) -> String? {
        guard index >= 0, index < tokens.count else { return nil }
        switch tokens[index].kind {
        case .backtick:
            return unquoteBacktick(tokens[index].text)
        case .identifier, .keyword, .function, .type:
            return tokens[index].text
        default:
            return nil
        }
    }

    private static func unquoteBacktick(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("`"), raw.hasSuffix("`") else { return raw }
        return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
    }

    private static func parseQualifiedName(_ tokens: [DDLToken], from index: Int)
        -> (database: String?, table: String, next: Int)? {
        guard let first = nameToken(tokens, at: index) else { return nil }
        if index + 2 < tokens.count,
           tokens[index + 1].kind == .punctuation, tokens[index + 1].text == ".",
           let second = nameToken(tokens, at: index + 2) {
            return (first, second, index + 3)
        }
        return (nil, first, index + 1)
    }

    private static func parseNameList(_ tokens: [DDLToken], from index: Int)
        -> [(database: String?, table: String, next: Int)] {
        var names: [(database: String?, table: String, next: Int)] = []
        var cursor = index
        while true {
            guard let parsed = parseQualifiedName(tokens, from: cursor) else { break }
            names.append(parsed)
            cursor = parsed.next
            if cursor < tokens.count, tokens[cursor].kind == .punctuation, tokens[cursor].text == "," {
                cursor += 1
                continue
            }
            break
        }
        return names
    }

    private static func isKeyword(_ tokens: [DDLToken], _ index: Int, _ word: String) -> Bool {
        guard index >= 0, index < tokens.count else { return false }
        return tokens[index].kind == .keyword && tokens[index].upper == word
    }

    /// `IF [NOT] EXISTS` 整体跳过；没命中时原样返回。
    private static func skippingIfClause(_ tokens: [DDLToken], from index: Int) -> Int {
        guard isKeyword(tokens, index, "IF") else { return index }
        var cursor = index + 1
        if isKeyword(tokens, cursor, "NOT") { cursor += 1 }
        if isKeyword(tokens, cursor, "EXISTS") { return cursor + 1 }
        return index
    }

    private static func append(_ parsed: (database: String?, table: String, next: Int)?,
                               into result: inout DDLInvalidation) {
        guard let parsed else {
            result.unresolved = true
            return
        }
        if let database = parsed.database, !database.isEmpty {
            result.tables.append(TableRef(database: database, table: parsed.table))
        } else if !parsed.table.isEmpty {
            result.unqualifiedTables.append(parsed.table)
        } else {
            result.unresolved = true
        }
    }

    // MARK: 小工具

    private static func tokens(_ extra: String?) -> [String] {
        guard let extra, !extra.isEmpty else { return [] }
        return extra.uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" })
            .map(String.init)
    }
}
