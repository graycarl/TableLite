import XCTest
@testable import TableLite

/// 表数据查询 SQL：列清单、大字段截断投影、稳定排序、显示条数。
///
/// 见 `docs/tech-designs/07-data-grid.md` §3、§7。
final class TableQueryBuilderTests: XCTestCase {

    private let columns: [ColumnInfo] = [
        TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63),
        TestSupport.column("name", type: .varString),
        TestSupport.column("content", type: .blob, charset: 63, dataType: "text"),
        TestSupport.column("created_at", type: .datetime),
    ]

    func testQueryProjectsLargeColumnsAndLimitsRows() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"],
            rowLimit: 300
        )
        XCTAssertEqual(
            query.sql,
            "SELECT `id`, `name`, LEFT(`content`, 4096) AS `content`, OCTET_LENGTH(`content`) AS `__mtl_len_2`, `created_at` "
                + "FROM `db`.`t` ORDER BY `id` ASC LIMIT 300"
        )
        XCTAssertEqual(query.limit, 300)
        XCTAssertEqual(query.offset, 0)
        XCTAssertEqual(query.orderByColumns, ["id"])
        XCTAssertTrue(query.projections[2].isTruncated)
        XCTAssertEqual(query.projections[2].lengthAlias, "__mtl_len_2")
        XCTAssertEqual(query.projections[2].sourceExpression, "`content`")
        XCTAssertFalse(query.projections[0].isTruncated)
    }

    func testQueryHasNoOffset() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"],
            rowLimit: 1000
        )
        XCTAssertTrue(query.sql.hasSuffix("LIMIT 1000"))
        XCTAssertFalse(query.sql.contains("OFFSET"))
    }

    func testNoPrimaryKeyOmitsOrderBy() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: [],
            rowLimit: 300
        )
        XCTAssertFalse(query.sql.contains("ORDER BY"))
        XCTAssertTrue(query.orderByColumns.isEmpty)
    }

    func testUserSortAppendsPrimaryKeyAsSecondary() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"],
            sort: [SortOrder(column: "name", direction: .descending)],
            rowLimit: 300
        )
        XCTAssertTrue(query.sql.contains("ORDER BY `name` DESC, `id` ASC"))
        XCTAssertEqual(query.orderByColumns, ["name", "id"])
    }

    func testUserSortOnPrimaryKeyIsNotDuplicated() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"],
            sort: [SortOrder(column: "id", direction: .descending)],
            rowLimit: 300
        )
        XCTAssertTrue(query.sql.contains("ORDER BY `id` DESC LIMIT 300"))
    }

    func testLazyLargeColumnsDisabledSkipsTruncation() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"],
            rowLimit: 300,
            options: TableQueryOptions(lazyLargeColumns: false)
        )
        XCTAssertFalse(query.sql.contains("LEFT("))
        XCTAssertFalse(query.sql.contains("OCTET_LENGTH"))
        XCTAssertTrue(query.projections.allSatisfy { !$0.isTruncated })
    }

    func testFilterClauseIsAppliedBeforeOrderBy() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"],
            filterClause: "`name` = 'a'",
            rowLimit: 300
        )
        XCTAssertTrue(query.sql.contains("FROM `db`.`t` WHERE `name` = 'a' ORDER BY `id` ASC"))
    }

    func testInvalidRowLimitFallsBackToDefault() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"],
            rowLimit: 0
        )
        XCTAssertEqual(query.limit, RowLimit.default)
    }

    func testSelectRowByKeyUsesFullColumnsAndLocator() throws {
        let locator = TestSupport.locator(id: "5")
        let query = try TableQueryBuilder.selectRowByKey(
            database: "db",
            table: "t",
            columns: columns,
            locator: locator
        )
        XCTAssertFalse(query.sql.contains("LEFT("))
        XCTAssertTrue(query.sql.contains("WHERE `id` = 5"))
        XCTAssertTrue(query.sql.hasSuffix("LIMIT 1"))
    }

    func testExportQueryHasNoLimitAndFullColumns() {
        let query = TableQueryBuilder.selectForExport(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"]
        )
        XCTAssertFalse(query.sql.contains("LEFT("))
        XCTAssertFalse(query.sql.contains("LIMIT"))
        XCTAssertTrue(query.sql.hasSuffix("ORDER BY `id` ASC"))
    }

    func testUnknownSortColumnIsDropped() {
        let query = TableQueryBuilder.selectRows(
            database: "db",
            table: "t",
            columns: columns,
            primaryKeyColumns: ["id"],
            sort: [SortOrder(column: "missing", direction: .ascending)],
            rowLimit: 300
        )
        XCTAssertFalse(query.sql.contains("missing"))
        XCTAssertTrue(query.sql.contains("ORDER BY `id` ASC"))
    }
}
