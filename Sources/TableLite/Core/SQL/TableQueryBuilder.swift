import Foundation

/// 结果集里的一列投影信息。见 `docs/tech-designs/07-data-grid.md` §2、§3.1。
public struct ColumnProjection: Sendable, Codable, Equatable, Hashable {
    /// 结果集列名（与表列同名）。
    public var name: String
    /// SELECT 里的表达式原文（可能带 `AS`）。
    public var expression: String
    /// 真实列引用（排序与 WHERE 必须用它，不能用截断前缀）。
    public var sourceExpression: String
    /// 是否是大字段截断投影。
    public var isTruncated: Bool
    /// 配套的长度列表达式（`OCTET_LENGTH(col)`），仅截断投影有。
    public var lengthExpression: String?
    /// 长度列的别名，网格消费后并入单元格状态。
    public var lengthAlias: String?

    public init(
        name: String,
        expression: String,
        sourceExpression: String,
        isTruncated: Bool = false,
        lengthExpression: String? = nil,
        lengthAlias: String? = nil
    ) {
        self.name = name
        self.expression = expression
        self.sourceExpression = sourceExpression
        self.isTruncated = isTruncated
        self.lengthExpression = lengthExpression
        self.lengthAlias = lengthAlias
    }
}

/// 生成好的表数据查询。
public struct TableQuery: Sendable, Equatable {
    public var sql: String
    public var projections: [ColumnProjection]
    public var limit: Int?
    public var offset: Int
    /// 实际使用的排序键（真实列名，按顺序）。
    public var orderByColumns: [String]

    public init(
        sql: String,
        projections: [ColumnProjection],
        limit: Int?,
        offset: Int,
        orderByColumns: [String]
    ) {
        self.sql = sql
        self.projections = projections
        self.limit = limit
        self.offset = offset
        self.orderByColumns = orderByColumns
    }
}

/// 表数据查询的生成选项。
public struct TableQueryOptions: Sendable, Equatable {
    /// 大字段两阶段加载开关（偏好 `grid.lazyLargeColumns`，默认开）。
    public var lazyLargeColumns: Bool
    /// 首屏截断长度（偏好，默认 4 KB）。
    public var largeColumnPrefixLength: Int
    public var escaping: SQLStringEscaping
    public var introducer: String?

    public init(
        lazyLargeColumns: Bool = true,
        largeColumnPrefixLength: Int = 4096,
        escaping: SQLStringEscaping = .mysqlDefault,
        introducer: String? = nil
    ) {
        self.lazyLargeColumns = lazyLargeColumns
        self.largeColumnPrefixLength = largeColumnPrefixLength
        self.escaping = escaping
        self.introducer = introducer
    }

    public static let `default` = TableQueryOptions()
}

/// 表数据视图的 SQL 生成。纯函数，见 `docs/tech-designs/07-data-grid.md` §3。
public enum TableQueryBuilder {
    /// 长度列别名前缀；网格据此识别长度列。
    public static let lengthAliasPrefix = "__mtl_len_"

    /// 分页查询：列清单 + 稳定排序 + `LIMIT pageSize + 1 OFFSET offset`。
    ///
    /// 查询 `pageSize + 1` 行用于判断是否有下一页，多出的一行不显示。
    public static func selectPage(
        database: String,
        table: String,
        columns: [ColumnInfo],
        primaryKeyColumns: [String],
        sort: [SortOrder] = [],
        filterClause: String? = nil,
        pageIndex: Int,
        pageSize: Int,
        options: TableQueryOptions = .default
    ) -> TableQuery {
        let effectivePageSize = PageSize.isValid(pageSize) ? pageSize : PageSize.default
        let offset = max(0, pageIndex) * effectivePageSize
        let projections = buildProjections(columns: columns, options: options)
        let orderBy = resolveOrderBy(
            sort: sort,
            primaryKeyColumns: primaryKeyColumns,
            availableColumns: columns.map(\.name)
        )
        let sql = buildSQL(
            database: database,
            table: table,
            projections: projections,
            filterClause: filterClause,
            orderBy: orderBy,
            limit: effectivePageSize + 1,
            offset: offset
        )
        return TableQuery(sql: sql, projections: projections, limit: effectivePageSize + 1, offset: offset, orderByColumns: orderBy.map(\.column))
    }

    /// 二次加载 / 定位单行：取完整列值，按行定位键过滤。
    public static func selectRowByKey(
        database: String,
        table: String,
        columns: [ColumnInfo],
        locator: RowLocator,
        options: TableQueryOptions = .default
    ) throws -> TableQuery {
        var fullOptions = options
        fullOptions.lazyLargeColumns = false
        let projections = buildProjections(columns: columns, options: fullOptions)
        let whereClause = try PendingChangeSQL.locationClause(
            locator,
            escaping: options.escaping,
            introducer: options.introducer
        )
        let sql = buildSQL(
            database: database,
            table: table,
            projections: projections,
            filterClause: whereClause,
            orderBy: [],
            limit: 1,
            offset: 0
        )
        return TableQuery(sql: sql, projections: projections, limit: 1, offset: 0, orderByColumns: [])
    }

    /// 导出查询：完整列值、稳定排序、不截断、默认不分页。
    public static func selectForExport(
        database: String,
        table: String,
        columns: [ColumnInfo],
        primaryKeyColumns: [String],
        sort: [SortOrder] = [],
        filterClause: String? = nil,
        limit: Int? = nil,
        offset: Int = 0,
        options: TableQueryOptions = .default
    ) -> TableQuery {
        var fullOptions = options
        fullOptions.lazyLargeColumns = false
        let projections = buildProjections(columns: columns, options: fullOptions)
        let orderBy = resolveOrderBy(
            sort: sort,
            primaryKeyColumns: primaryKeyColumns,
            availableColumns: columns.map(\.name)
        )
        let sql = buildSQL(
            database: database,
            table: table,
            projections: projections,
            filterClause: filterClause,
            orderBy: orderBy,
            limit: limit,
            offset: offset
        )
        return TableQuery(sql: sql, projections: projections, limit: limit, offset: offset, orderByColumns: orderBy.map(\.column))
    }

    // MARK: 内部

    static func buildProjections(columns: [ColumnInfo], options: TableQueryOptions) -> [ColumnProjection] {
        columns.enumerated().map { index, column in
            let source = SQLIdentifier.quote(column.name)
            if options.lazyLargeColumns, column.isLargeObject {
                let lengthAlias = "\(lengthAliasPrefix)\(index)"
                return ColumnProjection(
                    name: column.name,
                    expression: "LEFT(\(source), \(options.largeColumnPrefixLength)) AS \(source)",
                    sourceExpression: source,
                    isTruncated: true,
                    lengthExpression: "OCTET_LENGTH(\(source))",
                    lengthAlias: lengthAlias
                )
            }
            return ColumnProjection(
                name: column.name,
                expression: source,
                sourceExpression: source,
                isTruncated: false
            )
        }
    }

    /// 排序键 = 用户排序 + 主键次级排序；没有可用的排序键时返回空（省略 `ORDER BY`）。
    static func resolveOrderBy(
        sort: [SortOrder],
        primaryKeyColumns: [String],
        availableColumns: [String]
    ) -> [SortOrder] {
        let available = Set(availableColumns)
        var result: [SortOrder] = []
        var seen: Set<String> = []
        for item in sort where available.contains(item.column) && !seen.contains(item.column) {
            result.append(item)
            seen.insert(item.column)
        }
        for key in primaryKeyColumns where available.contains(key) && !seen.contains(key) {
            result.append(SortOrder(column: key, direction: .ascending))
            seen.insert(key)
        }
        return result
    }

    static func buildSQL(
        database: String,
        table: String,
        projections: [ColumnProjection],
        filterClause: String?,
        orderBy: [SortOrder],
        limit: Int?,
        offset: Int
    ) -> String {
        var selectItems: [String] = []
        for projection in projections {
            selectItems.append(projection.expression)
            if let lengthExpression = projection.lengthExpression, let alias = projection.lengthAlias {
                selectItems.append("\(lengthExpression) AS \(SQLIdentifier.quote(alias))")
            }
        }
        let selectList = selectItems.joined(separator: ", ")
        var sql = "SELECT \(selectList) FROM \(SQLIdentifier.qualified(database: database, table: table))"
        if let filterClause, !filterClause.isEmpty {
            sql += " WHERE \(filterClause)"
        }
        if !orderBy.isEmpty {
            let items = orderBy.map { "\(SQLIdentifier.quote($0.column)) \($0.direction.keyword)" }
            sql += " ORDER BY \(items.joined(separator: ", "))"
        }
        if let limit {
            sql += " LIMIT \(limit)"
            if offset > 0 { sql += " OFFSET \(offset)" }
        } else if offset > 0 {
            // MySQL 允许大 OFFSET 语法：LIMIT 18446744073709551615 OFFSET n
            sql += " LIMIT 18446744073709551615 OFFSET \(offset)"
        }
        return sql
    }
}
