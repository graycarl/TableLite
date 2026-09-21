import Foundation

// MARK: - 表数据分页模型
//
// 表数据视图的一页数据，以及每行的稳定身份。见 docs/tech-designs/07-data-grid.md §3。

/// 一行表数据。
///
/// `values` 与本次查询的投影列一一对应，也就是与 `structure.columns` 一一对应
///（列显隐不影响 SQL，隐藏列照样查询，见 specs/05-filtering.md §2）。
struct TableDataRow: Hashable, Sendable {
    /// 行身份：有主键时由主键值拼出；无主键时退化为「页码 + 行号」。
    var identity: RowIdentity
    /// 与 `structure.columns` 一一对应的单元格值。
    var values: [CellValue]
    /// 大字段被截断时，该列的真实长度（按 `CHAR_LENGTH` 计，文本按字符、二进制按字节）。
    /// 长度不超过阈值的列不写入这里（值本身就是完整的）。
    var truncatedLengths: [String: Int]
}

/// 一次分页查询的结果。
struct TableDataPage: Sendable {
    var rows: [TableDataRow]
    /// 查询了 `pageSize + 1` 行，据此判断是否还有下一页（多出的一行不返回）。
    var hasNextPage: Bool
    /// `information_schema.TABLES` 的估算行数；查询失败时为 nil。
    var rowEstimate: UInt64?
    var elapsed: Duration
    /// 主键列（按主键顺序）。
    var primaryKeyColumns: [String]
    /// 无主键表：分页顺序不保证且不可编辑。见 docs/tech-designs/07-data-grid.md §3.3。
    var hasPrimaryKey: Bool
}
