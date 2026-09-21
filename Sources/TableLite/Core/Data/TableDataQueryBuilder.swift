import Foundation

// MARK: - 表数据查询生成
//
// 纯函数、无 IO。见 docs/tech-designs/07-data-grid.md §3：
// - §3.1 大字段两阶段（`LEFT` 截断 + 长度列，排序必须用真实列名）；
// - §3.3 有主键按主键排序，用户排序追加主键作为次级排序键；无主键不写 ORDER BY；
// - §7 分页查询 `pageSize + 1` 行。
//
// 硬约束：
// - 表名 / 库名 / 列名一律 `SQLIdentifier`；
// - 值一律 `SQLValueLiteral` + `literalizer`，绝不手工拼接；
// - 长度列别名固定 `__mtl_len_<列名>`，追加在投影末尾。

/// 结果集里的一列投影：它来自哪个真实表列、结果别名是什么、是否是大字段截断投影。
struct TableColumnProjection: Hashable, Sendable {
    var tableColumnName: String
    var resultAlias: String
    var isTruncated: Bool
    /// 截断投影配套的长度列别名（`__mtl_len_<列名>`）；未截断为 nil。
    var lengthAlias: String?
}

enum TableDataQueryBuilder {

    /// 大字段截断阈值默认值（偏好可调）。
    static let defaultLargeThreshold = 4096
    /// 长度列别名前缀。网格消费后不显示该列。
    static let lengthAliasPrefix = "__mtl_len_"

    // MARK: 分页查询

    /// 生成一页数据的 `SELECT`。
    ///
    /// - `lazyLarge`：是否对大字段做截断投影（偏好 `grid.lazyLargeColumns`）。
    /// - `largeThreshold`：截断长度 N，默认 4096。
    ///
    /// 过滤器有 issue（含 raw 模式的分号）时抛 `MySQLError.unsupported`。
    /// 无主键时**不写** `ORDER BY`（顺序由服务器决定，分页结果不稳定，UI 只读）。
    static func pageSQL(ref: TableRef,
                        structure: TableStructure,
                        request: TablePageRequest,
                        lazyLarge: Bool,
                        largeThreshold: Int,
                        literalizer: SQLValueLiteralizer) throws -> String {
        let threshold = max(largeThreshold, 1)

        let filterResult = FilterSQLBuilder.build(
            request.filter,
            columns: structure.columns,
            using: literalizer
        )
        if let issue = filterResult.issues.first {
            throw MySQLError.unsupported(issue.message)
        }
        // `FilterSQLBuilder` 已把 raw 里的分号转成 issue，这里再兜一层，防呆。
        if request.filter.useRawSQL,
           request.filter.rawSQL.contains(";") {
            throw MySQLError.unsupported("高级条件不能包含分号「;」")
        }

        let projections = projection(
            structure: structure,
            lazyLarge: lazyLarge,
            largeThreshold: threshold
        )

        var sql = "SELECT \(selectList(ref: ref, projections: projections, largeThreshold: threshold))"
        sql += " FROM \(SQLIdentifier.qualified(ref.database, ref.table))"

        if let whereSQL = filterResult.sql, !whereSQL.isEmpty {
            sql += " WHERE \(whereSQL)"
        }
        if let orderBy = orderByClause(ref: ref, structure: structure, sort: request.sort) {
            sql += " ORDER BY \(orderBy)"
        }

        let pageSize = max(request.pageSize, 0)
        let offset = max(request.pageIndex, 0) * pageSize
        sql += " LIMIT \(pageSize + 1) OFFSET \(offset)"
        return sql
    }

    /// `SELECT` 列表：先是数据列（含截断表达式），最后追加长度列。
    static func selectList(ref: TableRef,
                           projections: [TableColumnProjection],
                           largeThreshold: Int) -> String {
        let table = SQLIdentifier.quote(ref.table)
        var items: [String] = projections.map { projection in
            let column = "\(table).\(SQLIdentifier.quote(projection.tableColumnName))"
            let alias = SQLIdentifier.quote(projection.resultAlias)
            if projection.isTruncated {
                return "LEFT(\(column), \(max(largeThreshold, 1))) AS \(alias)"
            }
            return "\(column) AS \(alias)"
        }
        for projection in projections {
            guard projection.isTruncated, let lengthAlias = projection.lengthAlias else { continue }
            let column = "\(table).\(SQLIdentifier.quote(projection.tableColumnName))"
            items.append("CHAR_LENGTH(\(column)) AS \(SQLIdentifier.quote(lengthAlias))")
        }
        return items.joined(separator: ", ")
    }

    /// `ORDER BY` 片段（不含关键字）。无主键时返回 nil。
    ///
    /// 用户排序只保留 `structure.columns` 里存在的列；随后追加主键列作为次级排序键
    ///（去重、保持顺序）。列名用**真实列名并限定表名**，不能用截断投影别名。
    static func orderByClause(ref: TableRef,
                              structure: TableStructure,
                              sort: [SortDescriptor]) -> String? {
        let primaryKey = structure.primaryKeyColumns.map(\.name)
        guard !primaryKey.isEmpty else { return nil }

        let available = Set(structure.columns.map(\.name))
        let table = SQLIdentifier.quote(ref.table)
        var seen = Set<String>()
        var terms: [String] = []

        for descriptor in sort where available.contains(descriptor.column) {
            guard seen.insert(descriptor.column).inserted else { continue }
            terms.append("\(table).\(SQLIdentifier.quote(descriptor.column)) \(descriptor.descending ? "DESC" : "ASC")")
        }
        for column in primaryKey where seen.insert(column).inserted {
            terms.append("\(table).\(SQLIdentifier.quote(column)) ASC")
        }
        return terms.joined(separator: ", ")
    }

    // MARK: 投影

    /// 列在结果集里的位置。返回顺序与 `structure.columns` 一一对应。
    ///
    /// 大字段（`column.isLargeObject && lazyLarge`）用 ``LEFT(`col`, N) AS `col` ``，
    /// 并记录长度列别名；长度列表由 `selectList` 追加在投影末尾。
    ///
    /// 默认 `lazyLarge = false` / 4096，方便直接按契约签名调用；`pageSQL` 总是显式传值。
    static func projection(structure: TableStructure,
                           lazyLarge: Bool = false,
                           largeThreshold: Int = defaultLargeThreshold) -> [TableColumnProjection] {
        structure.columns.map { column in
            let isTruncated = column.isLargeObject && lazyLarge
            return TableColumnProjection(
                tableColumnName: column.name,
                resultAlias: column.name,
                isTruncated: isTruncated,
                lengthAlias: isTruncated ? "\(lengthAliasPrefix)\(column.name)" : nil
            )
        }
    }

    // MARK: 大字段二次加载

    /// 取一行的大字段完整值（字段栏 / 快速查看 / 开始编辑时用）。
    ///
    /// 用行定位键（主键 + 修改前的值）限定，只查请求的列。列名与结果别名都用列名本身，
    /// 便于 Loader 按结果集列名回填。
    static func fullValueSQL(ref: TableRef,
                             structure: TableStructure,
                             locator: RowLocator,
                             columns: [TableColumn],
                             literalizer: SQLValueLiteralizer) -> String {
        let table = SQLIdentifier.quote(ref.table)
        let selectList: String
        if columns.isEmpty {
            selectList = "\(table).*"
        } else {
            selectList = columns
                .map { "\(table).\(SQLIdentifier.quote($0.name)) AS \(SQLIdentifier.quote($0.name))" }
                .joined(separator: ", ")
        }

        var sql = "SELECT \(selectList) FROM \(SQLIdentifier.qualified(ref.database, ref.table))"
        let whereSQL = whereClause(for: locator, structure: structure, literalizer: literalizer)
        if !whereSQL.isEmpty {
            sql += " WHERE \(whereSQL)"
        }
        return sql
    }

    // MARK: 行数

    /// 估算行数：`information_schema.TABLES` 的 `TABLE_ROWS`，绝不 `COUNT(*)`。
    /// 见 docs/tech-designs/07-data-grid.md §3.4。
    static func rowEstimateSQL(database: String,
                               table: String,
                               literalizer: SQLValueLiteralizer) -> String {
        let schema = SQLValueLiteral.literal(.text(database), kind: .text, using: literalizer)
        let name = SQLValueLiteral.literal(.text(table), kind: .text, using: literalizer)
        return "SELECT \(SQLIdentifier.quote("TABLE_ROWS"))"
            + " FROM \(SQLIdentifier.qualified("information_schema", "TABLES"))"
            + " WHERE \(SQLIdentifier.quote("TABLE_SCHEMA")) = \(schema)"
            + " AND \(SQLIdentifier.quote("TABLE_NAME")) = \(name)"
    }

    /// 精确统计：只在用户点「精确统计」时执行。
    static func preciseCountSQL(ref: TableRef,
                                whereClause: String?,
                                literalizer: SQLValueLiteralizer) -> String {
        var sql = "SELECT COUNT(*) AS \(SQLIdentifier.quote("row_count"))"
            + " FROM \(SQLIdentifier.qualified(ref.database, ref.table))"
        if let whereClause {
            let trimmed = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sql += " WHERE \(trimmed)"
            }
        }
        return sql
    }

    // MARK: 行定位条件

    /// 行定位条件（`` `id` = '1' AND `code` IS NULL ``，NULL 用 `IS NULL`）。
    ///
    /// 不知道列类型时按文本字面量处理（`SQLValueLiteral` 对非合法 UTF-8 会自动降级为 `0x…`），
    /// 字符串 PK 不会被误当成数字比较。已知结构时用下面的重载。
    static func whereClause(for locator: RowLocator, literalizer: SQLValueLiteralizer) -> String {
        whereClause(for: locator, columnKinds: [:], literalizer: literalizer)
    }

    /// 行定位条件（按 `structure` 里的列类型生成字面量）。
    static func whereClause(for locator: RowLocator,
                            structure: TableStructure,
                            literalizer: SQLValueLiteralizer) -> String {
        var kinds: [String: ColumnKind] = [:]
        for column in structure.columns {
            kinds[column.name] = column.kind
        }
        return whereClause(for: locator, columnKinds: kinds, literalizer: literalizer)
    }

    private static func whereClause(for locator: RowLocator,
                                    columnKinds: [String: ColumnKind],
                                    literalizer: SQLValueLiteralizer) -> String {
        var clauses: [String] = []
        for (name, value) in zip(locator.columns, locator.values) {
            let column = SQLIdentifier.quote(name)
            if value.isNull {
                clauses.append("\(column) IS NULL")
            } else {
                let kind = columnKinds[name] ?? .text
                clauses.append("\(column) = \(SQLValueLiteral.literal(value, kind: kind, using: literalizer))")
            }
        }
        return clauses.joined(separator: " AND ")
    }
}
