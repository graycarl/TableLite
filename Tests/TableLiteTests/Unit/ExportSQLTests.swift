import XCTest
@testable import TableLite

/// 导出用纯逻辑：顶层 LIMIT 剥离、表导出 SQL、选中行导出 SQL、过滤摘要。
/// 见 docs/tech-designs/11-schema-and-import-export.md §3.1 §3.2、specs/08-import-export.md §1。
final class ExportSQLTests: XCTestCase {

    private let literalizer = SQLValueLiteralizer.conservative
    private let ref = TableRef(database: "db", table: "t")

    // MARK: - 构造辅助

    private func col(_ name: String,
                     _ dataType: String,
                     raw: String? = nil,
                     pk: Bool = false,
                     nullable: Bool = true) -> TableColumn {
        TableColumn(name: name, dataType: dataType, rawTypeText: raw ?? dataType,
                    isNullable: nullable, isPrimaryKey: pk)
    }

    private func structure(_ columns: [TableColumn]) -> TableStructure {
        TableStructure(ref: ref,
                       kind: .table,
                       comment: nil,
                       columns: columns,
                       indexes: [],
                       foreignKeys: [],
                       triggers: [],
                       createStatement: "")
    }

    // MARK: - 顶层 LIMIT 剥离

    func testStripsTopLevelLimit() {
        let result = ExportSQL.stripTopLevelLimit("SELECT * FROM `t` LIMIT 100")
        XCTAssertEqual(result, .stripped("SELECT * FROM `t`"))
        XCTAssertTrue(result.didStripLimit)
        XCTAssertFalse(result.isAmbiguous)
    }

    func testNoLimitIsUnchanged() {
        let sql = "SELECT * FROM `t` WHERE `id` > 10"
        let result = ExportSQL.stripTopLevelLimit(sql)
        XCTAssertEqual(result, .unchanged(sql))
        XCTAssertFalse(result.didStripLimit)
        XCTAssertFalse(result.isAmbiguous)
    }

    func testLimitInSubqueryIsUnchanged() {
        let sql = "SELECT * FROM (SELECT * FROM `t` LIMIT 10) AS `x`"
        XCTAssertEqual(ExportSQL.stripTopLevelLimit(sql), .unchanged(sql))
    }

    func testTopLevelUnionIsAmbiguous() {
        let sql = "SELECT `a` FROM `t` UNION SELECT `b` FROM `u` LIMIT 5"
        XCTAssertEqual(ExportSQL.stripTopLevelLimit(sql), .ambiguous(sql))
    }

    func testLowercaseLimitIsStripped() {
        let result = ExportSQL.stripTopLevelLimit("select * from t limit 10")
        XCTAssertEqual(result, .stripped("select * from t"))
    }

    func testLimitWithOffsetIsStripped() {
        XCTAssertEqual(ExportSQL.stripTopLevelLimit("SELECT * FROM `t` LIMIT 10 OFFSET 20"),
                       .stripped("SELECT * FROM `t`"))
    }

    func testLimitCommaFormIsStripped() {
        XCTAssertEqual(ExportSQL.stripTopLevelLimit("SELECT * FROM `t` LIMIT 20, 10"),
                       .stripped("SELECT * FROM `t`"))
    }

    func testLimitWithTrailingSemicolonKeepsPrefixOnly() {
        XCTAssertEqual(ExportSQL.stripTopLevelLimit("SELECT * FROM `t` LIMIT 10;"),
                       .stripped("SELECT * FROM `t`"))
    }

    func testLimitFollowedByAnotherClauseIsAmbiguous() {
        let sql = "SELECT * FROM `t` LIMIT 10 FOR UPDATE"
        XCTAssertEqual(ExportSQL.stripTopLevelLimit(sql), .ambiguous(sql))
    }

    func testLimitInsideStringIsNotStripped() {
        let sql = "SELECT 'LIMIT 10' AS `s` FROM `t`"
        XCTAssertEqual(ExportSQL.stripTopLevelLimit(sql), .unchanged(sql))
    }

    func testLimitWithoutOperandIsAmbiguous() {
        let sql = "SELECT * FROM `t` LIMIT"
        XCTAssertEqual(ExportSQL.stripTopLevelLimit(sql), .ambiguous(sql))
    }

    func testPlaceholderLimitIsStripped() {
        XCTAssertEqual(ExportSQL.stripTopLevelLimit("SELECT * FROM `t` LIMIT ?"),
                       .stripped("SELECT * FROM `t`"))
    }

    // MARK: - 表导出 SQL

    func testExportSQLHasNoLimitOrOffset() throws {
        let s = structure([col("id", "int", pk: true), col("name", "varchar", raw: "varchar(255)")])
        let sql = try TableDataQueryBuilder.exportSQL(
            ref: ref,
            structure: s,
            filter: FilterSet(),
            sort: [],
            literalizer: literalizer
        )
        XCTAssertFalse(sql.contains("LIMIT"))
        XCTAssertFalse(sql.contains("OFFSET"))
        XCTAssertEqual(
            sql,
            "SELECT `t`.`id` AS `id`, `t`.`name` AS `name` FROM `db`.`t` ORDER BY `t`.`id` ASC"
        )
    }

    func testExportSQLIncludesWhereAndSort() throws {
        let s = structure([col("id", "int", pk: true), col("status", "varchar", raw: "varchar(20)")])
        var filter = FilterSet()
        filter.conditions = [
            FilterCondition(enabled: true, column: "status", op: .equal, value: "published")
        ]
        let sql = try TableDataQueryBuilder.exportSQL(
            ref: ref,
            structure: s,
            filter: filter,
            sort: [SortDescriptor(column: "status", descending: true)],
            literalizer: literalizer
        )
        XCTAssertTrue(sql.contains("WHERE (`status` = 'published')"), sql)
        XCTAssertTrue(sql.contains("ORDER BY `t`.`status` DESC, `t`.`id` ASC"), sql)
        XCTAssertFalse(sql.contains("LIMIT"), sql)
    }

    func testExportSQLWithoutPrimaryKeyHasNoOrderBy() throws {
        let s = structure([col("a", "int"), col("b", "int")])
        let sql = try TableDataQueryBuilder.exportSQL(
            ref: ref,
            structure: s,
            filter: FilterSet(),
            sort: [],
            literalizer: literalizer
        )
        XCTAssertFalse(sql.contains("ORDER BY"), sql)
        XCTAssertFalse(sql.contains("LIMIT"), sql)
    }

    func testExportSQLThrowsOnFilterIssue() {
        let s = structure([col("id", "int", pk: true)])
        var filter = FilterSet()
        filter.conditions = [
            FilterCondition(enabled: true, column: "missing", op: .equal, value: "x")
        ]
        XCTAssertThrowsError(
            try TableDataQueryBuilder.exportSQL(
                ref: ref,
                structure: s,
                filter: filter,
                sort: [],
                literalizer: literalizer
            )
        )
    }

    // MARK: - 选中行导出 SQL

    func testSelectedRowsSQLJoinsLocatorsWithOr() {
        let s = structure([col("id", "int", pk: true), col("name", "varchar", raw: "varchar(50)")])
        let locators = [
            RowLocator(columns: ["id"], values: [.text("1")]),
            RowLocator(columns: ["id"], values: [.null])
        ]
        let sql = ExportSQL.selectedRowsSQL(ref: ref, structure: s,
                                            locators: locators, literalizer: literalizer)
        XCTAssertEqual(
            sql,
            "SELECT `t`.`id` AS `id`, `t`.`name` AS `name` FROM `db`.`t`"
                + " WHERE (`id` = 1) OR (`id` IS NULL)"
        )
    }

    func testSelectedRowsSQLReturnsNilWithoutLocator() {
        let s = structure([col("id", "int", pk: true)])
        XCTAssertNil(ExportSQL.selectedRowsSQL(ref: ref, structure: s,
                                               locators: [RowLocator(columns: [], values: [])],
                                               literalizer: literalizer))
    }

    // MARK: - 过滤摘要

    func testFilterSummaryEmpty() {
        XCTAssertNil(ExportSQL.filterSummary(FilterSet()))
    }

    func testFilterSummaryConditions() {
        var filter = FilterSet()
        filter.conditions = [
            FilterCondition(enabled: true, column: "status", op: .equal, value: "published"),
            FilterCondition(enabled: true, column: "deleted_at", op: .isNull)
        ]
        XCTAssertEqual(ExportSQL.filterSummary(filter), "status 等于 published 且 deleted_at 为空")
    }
}
