import Foundation

/// 暂存变更 SQL 生成错误。
public enum PendingChangeSQLError: Error, Sendable, Equatable {
    case emptyLocator(PendingChange.Kind)
    case emptyUpdateEdits

    public var message: String {
        switch self {
        case .emptyLocator(let kind):
            return "\(kind.displayName)行的定位键为空，无法生成 SQL"
        case .emptyUpdateEdits:
            return "修改行没有任何已编辑的列，无法生成 UPDATE"
        }
    }
}

/// 由暂存变更生成 INSERT / UPDATE / DELETE。
///
/// 规则见 `docs/tech-designs/08-pending-changes.md` §3：
/// - INSERT 只包含用户实际填过的列；一列都没填时 `INSERT INTO t () VALUES ()`；
/// - UPDATE 的 WHERE 用全部行定位键、AND 连接，NULL 用 `IS NULL`；
/// - SET 按列在表中的顺序输出；
/// - 语句顺序固定为 INSERT → UPDATE → DELETE。
///
/// 需要表的列元数据来判断字面量是否去引号（`03-mysql-layer.md` §4.2）。
public enum PendingChangeSQL {
    /// 从暂存区生成全部语句。
    public static func statements(
        for store: PendingChangeStore,
        database: String,
        table: String,
        columns: [ColumnInfo],
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) throws -> [String] {
        try statements(
            for: store.changes,
            database: database,
            table: table,
            columns: columns,
            escaping: escaping,
            introducer: introducer,
            escaper: escaper
        )
    }

    /// 从一组变更生成全部语句。
    public static func statements(
        for changes: [PendingChange],
        database: String,
        table: String,
        columns: [ColumnInfo],
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) throws -> [String] {
        let qualifiedTable = SQLIdentifier.qualified(database: database, table: table)
        var statements: [String] = []

        // INSERT → UPDATE → DELETE；同类型内保持用户操作顺序。
        for change in changes {
            if case .insertion(_, let edits) = change {
                statements.append(
                    insertStatement(
                        table: qualifiedTable,
                        edits: edits,
                        columns: columns,
                        escaping: escaping,
                        introducer: introducer,
                        escaper: escaper
                    )
                )
            }
        }
        for change in changes {
            if case .update(let locator, let edits) = change {
                statements.append(
                    try updateStatement(
                        table: qualifiedTable,
                        edits: edits,
                        locator: locator,
                        columns: columns,
                        escaping: escaping,
                        introducer: introducer,
                        escaper: escaper
                    )
                )
            }
        }
        for change in changes {
            if case .deletion(let locator) = change {
                statements.append(
                    try deleteStatement(
                        table: qualifiedTable,
                        locator: locator,
                        escaping: escaping,
                        introducer: introducer,
                        escaper: escaper
                    )
                )
            }
        }
        return statements
    }

    // MARK: 单条语句

    public static func insertStatement(
        table: String,
        edits: [PendingEdit],
        columns: [ColumnInfo],
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) -> String {
        let ordered = orderedEdits(edits, columns: columns)
        guard !ordered.isEmpty else {
            // 一列都没填：交给服务器默认值。
            return "INSERT INTO \(table) () VALUES ()"
        }
        let columnNames = SQLIdentifier.quoteList(ordered.map(\.column))
        let values = ordered.map { edit in
            literal(for: edit, columns: columns, escaping: escaping, introducer: introducer, escaper: escaper)
        }.joined(separator: ", ")
        return "INSERT INTO \(table) (\(columnNames)) VALUES (\(values))"
    }

    public static func updateStatement(
        table: String,
        edits: [PendingEdit],
        locator: RowLocator,
        columns: [ColumnInfo],
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) throws -> String {
        guard !edits.isEmpty else { throw PendingChangeSQLError.emptyUpdateEdits }
        let ordered = orderedEdits(edits, columns: columns)
        let assignments = ordered.map { edit in
            let value = literal(for: edit, columns: columns, escaping: escaping, introducer: introducer, escaper: escaper)
            return "\(SQLIdentifier.quote(edit.column)) = \(value)"
        }.joined(separator: ", ")
        let whereClause = try locationClause(locator, escaping: escaping, introducer: introducer, escaper: escaper)
        return "UPDATE \(table) SET \(assignments) WHERE \(whereClause)"
    }

    public static func deleteStatement(
        table: String,
        locator: RowLocator,
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) throws -> String {
        let whereClause = try locationClause(locator, escaping: escaping, introducer: introducer, escaper: escaper)
        return "DELETE FROM \(table) WHERE \(whereClause)"
    }

    /// 行定位子句：全部定位键用 `AND` 连接，NULL 用 `IS NULL`。
    public static func locationClause(
        _ locator: RowLocator,
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) throws -> String {
        guard !locator.isEmpty else { throw PendingChangeSQLError.emptyLocator(.update) }
        return locator.keys.map { key in
            let column = SQLIdentifier.quote(key.column)
            switch key.value {
            case .null:
                return "\(column) IS NULL"
            default:
                let value = keyLiteral(key, escaping: escaping, introducer: introducer, escaper: escaper)
                return "\(column) = \(value)"
            }
        }.joined(separator: " AND ")
    }

    // MARK: 辅助

    private static func keyLiteral(
        _ key: RowKeyValue,
        escaping: SQLStringEscaping,
        introducer: String?,
        escaper: SQLValueLiteral.StringEscaper?
    ) -> String {
        if let escaper {
            return SQLValueLiteral.literal(
                for: key.value,
                fieldType: key.fieldType,
                isBinaryColumn: key.isBinary,
                escaper: escaper,
                introducer: introducer
            )
        }
        return SQLValueLiteral.literal(
            for: key.value,
            fieldType: key.fieldType,
            isBinaryColumn: key.isBinary,
            escaping: escaping,
            introducer: introducer
        )
    }

    /// 按列在表中的顺序排列；不在 `columns` 里的列保持原顺序放最后，保证确定性。
    static func orderedEdits(_ edits: [PendingEdit], columns: [ColumnInfo]) -> [PendingEdit] {
        var order: [String: Int] = [:]
        for (index, column) in columns.enumerated() { order[column.name] = index }
        return edits.enumerated().sorted { lhs, rhs in
            let lhsOrder = order[lhs.element.column] ?? Int.max
            let rhsOrder = order[rhs.element.column] ?? Int.max
            if lhsOrder == rhsOrder { return lhs.offset < rhs.offset }
            return lhsOrder < rhsOrder
        }.map(\.element)
    }

    static func literal(
        for edit: PendingEdit,
        columns: [ColumnInfo],
        escaping: SQLStringEscaping,
        introducer: String?,
        escaper: SQLValueLiteral.StringEscaper? = nil
    ) -> String {
        if let column = columns.first(where: { $0.name == edit.column }) {
            if let escaper {
                return SQLValueLiteral.literal(
                    for: edit.value,
                    column: column,
                    escaper: escaper,
                    introducer: introducer
                )
            }
            return SQLValueLiteral.literal(
                for: edit.value,
                column: column,
                escaping: escaping,
                introducer: introducer
            )
        }
        // 元数据缺失时保守走字符串路径，永不拼接未验证内容。
        if let escaper {
            return SQLValueLiteral.literal(
                for: edit.value,
                fieldType: .varString,
                escaper: escaper,
                introducer: introducer
            )
        }
        return SQLValueLiteral.literal(
            for: edit.value,
            fieldType: .varString,
            escaping: escaping,
            introducer: introducer
        )
    }
}
