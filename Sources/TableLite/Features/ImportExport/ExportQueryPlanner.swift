import Foundation

/// 已解析好的导出计划：可直接交给 `CSVExportEngine` 执行。
public struct ExportPlan: Sendable, Equatable {
    /// 实际下发的 SQL。
    public var sql: String
    public var database: String?
    /// 已知的表头列名（表 / 选中行导出）；查询结果导出为 nil，运行时从结果集头取。
    public var header: [String]?
    /// 已知列元数据，用于把原始字节映射成 `SQLValue`（二进制 / NULL）。
    /// 查询结果导出为空，运行时用结果集头。
    public var columns: [ColumnInfo]
    public var sourceTitle: String
    public var sourceDetail: String
    /// LIMIT 处理说明；nil 表示无需提示。
    public var limitNote: String?

    public init(
        sql: String,
        database: String? = nil,
        header: [String]? = nil,
        columns: [ColumnInfo] = [],
        sourceTitle: String,
        sourceDetail: String,
        limitNote: String? = nil
    ) {
        self.sql = sql
        self.database = database
        self.header = header
        self.columns = columns
        self.sourceTitle = sourceTitle
        self.sourceDetail = sourceDetail
        self.limitNote = limitNote
    }
}

/// 导出 SQL 生成。纯函数。
public enum ExportQueryPlanner {

    /// 表 / 带过滤条件的表 / 选中行导出：走 `TableQueryBuilder.selectForExport`（不截断、稳定排序）。
    public static func planTable(
        database: String,
        table: String,
        columns: [ColumnInfo],
        primaryKeyColumns: [String],
        filterClause: String?,
        sourceDetail: String,
        sort: [SortOrder] = []
    ) -> ExportPlan {
        let query = TableQueryBuilder.selectForExport(
            database: database,
            table: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            sort: sort,
            filterClause: filterClause
        )
        return ExportPlan(
            sql: query.sql,
            database: database,
            header: query.projections.map(\.name),
            columns: columns,
            sourceTitle: "\(database).\(table)",
            sourceDetail: sourceDetail
        )
    }

    /// 查询结果导出：尽量剥掉顶层 `LIMIT`；不确定时保留原 SQL 并给出说明。
    public static func planQuery(sql: String, description: String) -> ExportPlan {
        let removal = SQLLimitRemoval.removingTopLevelLimit(sql)
        return ExportPlan(
            sql: removal.sql,
            database: nil,
            header: nil,
            columns: [],
            sourceTitle: description,
            sourceDetail: "该查询结果集的全部行",
            limitNote: removal.note
        )
    }

    /// 选中行导出：`whereClause` 是不带 `WHERE` 的定位条件。
    public static func planSelectedRows(
        database: String,
        table: String,
        columns: [ColumnInfo],
        whereClause: String,
        rowCount: Int
    ) -> ExportPlan {
        let query = TableQueryBuilder.selectForExport(
            database: database,
            table: table,
            columns: columns,
            primaryKeyColumns: [],
            filterClause: whereClause
        )
        return ExportPlan(
            sql: query.sql,
            database: database,
            header: query.projections.map(\.name),
            columns: columns,
            sourceTitle: "\(database).\(table)（选中行）",
            sourceDetail: "仅导出选中的 \(rowCount) 行"
        )
    }
}
