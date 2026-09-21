import XCTest
@testable import TableLite

/// 表数据查询生成的纯函数边界。见 docs/tech-designs/07-data-grid.md §3 §7。
final class TableDataQueryBuilderTests: XCTestCase {

    private let literalizer = SQLValueLiteralizer.conservative
    private let ref = TableRef(database: "db", table: "t")

    // MARK: 构造辅助

    private func col(_ name: String,
                     _ dataType: String,
                     raw: String? = nil,
                     pk: Bool = false) -> TableColumn {
        TableColumn(name: name, dataType: dataType, rawTypeText: raw ?? dataType, isPrimaryKey: pk)
    }

    private func structure(_ columns: [TableColumn],
                           ref: TableRef = TableRef(database: "db", table: "t")) -> TableStructure {
        TableStructure(ref: ref,
                       kind: .table,
                       comment: nil,
                       columns: columns,
                       indexes: [],
                       foreignKeys: [],
                       triggers: [],
                       createStatement: "")
    }

    private func request(pageIndex: Int = 0,
                         pageSize: Int = 300,
                         sort: [TableLite.SortDescriptor] = [],
                         filter: FilterSet = FilterSet()) -> TablePageRequest {
        TablePageRequest(schema: "db",
                         table: "t",
                         pageIndex: pageIndex,
                         pageSize: pageSize,
                         sort: sort,
                         filter: filter)
    }

    private func pageSQL(_ structure: TableStructure,
                         request: TablePageRequest,
                         ref: TableRef? = nil,
                         lazyLarge: Bool = true,
                         largeThreshold: Int = 4096) throws -> String {
        try TableDataQueryBuilder.pageSQL(ref: ref ?? self.ref,
                                          structure: structure,
                                          request: request,
                                          lazyLarge: lazyLarge,
                                          largeThreshold: largeThreshold,
                                          literalizer: literalizer)
    }

    // MARK: 基本投影 / ORDER BY / 分页

    func testSimplePageSQL() throws {
        let s = structure([col("id", "int", pk: true),
                           col("age", "int")])
        let sql = try pageSQL(s, request: request())
        XCTAssertEqual(
            sql,
            "SELECT `t`.`id` AS `id`, `t`.`age` AS `age`"
                + " FROM `db`.`t`"
                + " ORDER BY `t`.`id` ASC"
                + " LIMIT 301 OFFSET 0"
        )
    }

    func testPaginationUsesPageSizePlusOneAndOffset() throws {
        let s = structure([col("id", "int", pk: true)])
        let sql = try pageSQL(s, request: request(pageIndex: 2, pageSize: 100))
        XCTAssertTrue(sql.hasSuffix("LIMIT 101 OFFSET 200"), sql)
    }

    // MARK: 排序

    func testUserSortAppendsPrimaryKey() throws {
        let s = structure([col("id", "int", pk: true),
                           col("name", "varchar", raw: "varchar(255)")])
        let sql = try pageSQL(s, request: request(sort: [TableLite.SortDescriptor(column: "name", descending: true)]))
        XCTAssertTrue(sql.contains("ORDER BY `t`.`name` DESC, `t`.`id` ASC"), sql)
    }

    func testUserSortOnPrimaryKeyIsNotDuplicated() throws {
        let s = structure([col("id", "int", pk: true),
                           col("name", "varchar", raw: "varchar(255)")])
        let sql = try pageSQL(s, request: request(sort: [TableLite.SortDescriptor(column: "id", descending: true)]))
        XCTAssertTrue(sql.contains("ORDER BY `t`.`id` DESC"), sql)
        XCTAssertFalse(sql.contains("`t`.`id` DESC, `t`.`id` ASC"), sql)
    }

    func testDefaultOrderIsPrimaryKey() throws {
        let s = structure([col("id", "int", pk: true),
                           col("name", "varchar", raw: "varchar(255)")])
        let sql = try pageSQL(s, request: request())
        XCTAssertTrue(sql.contains("ORDER BY `t`.`id` ASC"), sql)
    }

    func testNoPrimaryKeyOmitsOrderBy() throws {
        let s = structure([col("name", "varchar", raw: "varchar(255)")])
        let sql = try pageSQL(s, request: request())
        XCTAssertFalse(sql.contains("ORDER BY"), sql)
    }

    func testSortOnUnknownColumnIsIgnored() throws {
        let s = structure([col("id", "int", pk: true)])
        let sql = try pageSQL(s, request: request(sort: [TableLite.SortDescriptor(column: "missing", descending: true)]))
        XCTAssertTrue(sql.contains("ORDER BY `t`.`id` ASC"), sql)
        XCTAssertFalse(sql.contains("missing"), sql)
    }

    func testOrderByUsesRealQualifiedColumnForTruncatedLargeObject() throws {
        let s = structure([col("id", "int", pk: true),
                           col("content", "longtext", raw: "longtext")])
        let sql = try pageSQL(s, request: request(sort: [TableLite.SortDescriptor(column: "content", descending: false)]))
        // 必须用真实列名排序，不能按截断前缀 / 别名排序
        XCTAssertTrue(sql.contains("ORDER BY `t`.`content` ASC, `t`.`id` ASC"), sql)
        XCTAssertTrue(sql.contains("LEFT(`t`.`content`, 4096) AS `content`"), sql)
    }

    // MARK: 大字段两阶段

    func testProjectionTruncatesLargeObjectAndAddsLengthAlias() {
        let s = structure([col("id", "int", pk: true),
                           col("content", "longtext", raw: "longtext")])
        let projections = TableDataQueryBuilder.projection(structure: s, lazyLarge: true, largeThreshold: 4096)
        XCTAssertEqual(projections.count, 2)
        XCTAssertEqual(projections[0].tableColumnName, "id")
        XCTAssertEqual(projections[0].resultAlias, "id")
        XCTAssertFalse(projections[0].isTruncated)
        XCTAssertNil(projections[0].lengthAlias)

        XCTAssertTrue(projections[1].isTruncated)
        XCTAssertEqual(projections[1].lengthAlias, "__mtl_len_content")
    }

    func testLargeObjectSelectListAppendsLengthColumnsAtEnd() throws {
        let s = structure([col("id", "int", pk: true),
                           col("content", "longtext", raw: "longtext"),
                           col("age", "int")])
        let sql = try pageSQL(s, request: request(), largeThreshold: 1024)
        let selected = "SELECT `t`.`id` AS `id`, LEFT(`t`.`content`, 1024) AS `content`,"
            + " `t`.`age` AS `age`, CHAR_LENGTH(`t`.`content`) AS `__mtl_len_content`"
        XCTAssertTrue(sql.hasPrefix(selected), sql)
    }

    func testLazyLargeDisabledProducesNoTruncation() throws {
        let s = structure([col("id", "int", pk: true),
                           col("content", "longtext", raw: "longtext")])
        let sql = try pageSQL(s, request: request(), lazyLarge: false)
        XCTAssertFalse(sql.contains("LEFT("), sql)
        XCTAssertFalse(sql.contains("__mtl_len_"), sql)
    }

    func testNoLargeObjectProducesNoLengthColumn() throws {
        let s = structure([col("id", "int", pk: true),
                           col("age", "int")])
        let sql = try pageSQL(s, request: request())
        XCTAssertFalse(sql.contains("LEFT("), sql)
        XCTAssertFalse(sql.contains("CHAR_LENGTH"), sql)
        XCTAssertFalse(sql.contains("__mtl_len_"), sql)
    }

    // MARK: WHERE

    func testFilterConditionAppearsInWhere() throws {
        let s = structure([col("id", "int", pk: true),
                           col("name", "varchar", raw: "varchar(255)")])
        let filter = FilterSet(conditions: [
            FilterCondition(column: "name", op: .equal, value: "Alice"),
        ])
        let sql = try pageSQL(s, request: request(filter: filter))
        XCTAssertTrue(sql.contains("WHERE (`name` = 'Alice')"), sql)
    }

    func testLikeFilterUsesExplicitEscape() throws {
        let s = structure([col("id", "int", pk: true),
                           col("name", "varchar", raw: "varchar(255)")])
        let filter = FilterSet(conditions: [
            FilterCondition(column: "name", op: .contains, value: "a%b"),
        ])
        let sql = try pageSQL(s, request: request(filter: filter))
        XCTAssertTrue(sql.contains("LIKE '%a\\\\%b%' ESCAPE '\\\\'"), sql)
    }

    func testRawFilterWithSemicolonThrows() {
        let s = structure([col("id", "int", pk: true)])
        let filter = FilterSet(rawSQL: "1 = 1; DROP TABLE `t`", useRawSQL: true)
        XCTAssertThrowsError(try pageSQL(s, request: request(filter: filter))) { error in
            guard case MySQLError.unsupported(let message) = error else {
                return XCTFail("期望 MySQLError.unsupported，实得 \(error)")
            }
            XCTAssertTrue(message.contains("分号"), message)
        }
    }

    func testRawFilterWithoutSemicolonIsUsedAsIs() throws {
        let s = structure([col("id", "int", pk: true),
                           col("name", "varchar", raw: "varchar(255)")])
        let filter = FilterSet(rawSQL: "`name` IN ('a', 'b')", useRawSQL: true)
        let sql = try pageSQL(s, request: request(filter: filter))
        XCTAssertTrue(sql.contains("WHERE `name` IN ('a', 'b')"), sql)
    }

    func testUnknownFilterColumnThrows() {
        let s = structure([col("id", "int", pk: true)])
        let filter = FilterSet(conditions: [
            FilterCondition(column: "nope", op: .equal, value: "1"),
        ])
        XCTAssertThrowsError(try pageSQL(s, request: request(filter: filter))) { error in
            guard case MySQLError.unsupported = error else {
                return XCTFail("期望 MySQLError.unsupported，实得 \(error)")
            }
        }
    }

    // MARK: 行定位条件

    func testWhereClauseNormalValue() {
        let locator = RowLocator(columns: ["id"], values: [.text("1")])
        XCTAssertEqual(
            TableDataQueryBuilder.whereClause(for: locator, literalizer: literalizer),
            "`id` = '1'"
        )
    }

    func testWhereClauseNullUsesIsNull() {
        let locator = RowLocator(columns: ["code"], values: [.null])
        XCTAssertEqual(
            TableDataQueryBuilder.whereClause(for: locator, literalizer: literalizer),
            "`code` IS NULL"
        )
    }

    func testWhereClauseCompositeKeyAndsConditions() {
        let locator = RowLocator(columns: ["a", "b"], values: [.text("1"), .null])
        XCTAssertEqual(
            TableDataQueryBuilder.whereClause(for: locator, literalizer: literalizer),
            "`a` = '1' AND `b` IS NULL"
        )
    }

    func testWhereClauseUsesColumnKindWhenStructureIsKnown() {
        let s = structure([col("id", "int", pk: true)])
        let locator = RowLocator(columns: ["id"], values: [.text("1")])
        XCTAssertEqual(
            TableDataQueryBuilder.whereClause(for: locator, structure: s, literalizer: literalizer),
            "`id` = 1"
        )
    }

    func testWhereClauseEscapesBackticksInColumnName() {
        let locator = RowLocator(columns: ["we`ird"], values: [.text("x")])
        XCTAssertEqual(
            TableDataQueryBuilder.whereClause(for: locator, literalizer: literalizer),
            "`we``ird` = 'x'"
        )
    }

    // MARK: 大字段二次加载

    func testFullValueSQL() {
        let s = structure([col("id", "int", pk: true),
                           col("content", "longtext", raw: "longtext")])
        let locator = RowLocator(columns: ["id"], values: [.text("5")])
        let sql = TableDataQueryBuilder.fullValueSQL(ref: ref,
                                                     structure: s,
                                                     locator: locator,
                                                     columns: [s.columns[1]],
                                                     literalizer: literalizer)
        XCTAssertEqual(sql, "SELECT `t`.`content` AS `content` FROM `db`.`t` WHERE `id` = 5")
    }

    func testFullValueSQLWithNullLocatorValue() {
        let s = structure([col("code", "varchar", raw: "varchar(32)", pk: true),
                           col("content", "longtext", raw: "longtext")])
        let locator = RowLocator(columns: ["code"], values: [.null])
        let sql = TableDataQueryBuilder.fullValueSQL(ref: ref,
                                                     structure: s,
                                                     locator: locator,
                                                     columns: [s.columns[1]],
                                                     literalizer: literalizer)
        XCTAssertTrue(sql.contains("WHERE `code` IS NULL"), sql)
    }

    // MARK: 行数

    func testRowEstimateSQL() {
        XCTAssertEqual(
            TableDataQueryBuilder.rowEstimateSQL(database: "db", table: "t", literalizer: literalizer),
            "SELECT `TABLE_ROWS` FROM `information_schema`.`TABLES`"
                + " WHERE `TABLE_SCHEMA` = 'db' AND `TABLE_NAME` = 't'"
        )
    }

    func testPreciseCountSQL() {
        XCTAssertEqual(
            TableDataQueryBuilder.preciseCountSQL(ref: ref, whereClause: nil, literalizer: literalizer),
            "SELECT COUNT(*) AS `row_count` FROM `db`.`t`"
        )
        XCTAssertEqual(
            TableDataQueryBuilder.preciseCountSQL(ref: ref, whereClause: "`id` > 10", literalizer: literalizer),
            "SELECT COUNT(*) AS `row_count` FROM `db`.`t` WHERE `id` > 10"
        )
    }

    // MARK: 标识符转义

    func testIdentifiersWithBackticksAreEscaped() throws {
        let weirdRef = TableRef(database: "we`ird", table: "ta`ble")
        let s = structure([col("co`l", "int", pk: true)], ref: weirdRef)
        let sql = try pageSQL(s, request: request(), ref: weirdRef)
        XCTAssertTrue(sql.contains("FROM `we``ird`.`ta``ble`"), sql)
        XCTAssertTrue(sql.contains("`ta``ble`.`co``l`"), sql)
        XCTAssertTrue(sql.contains("ORDER BY `ta``ble`.`co``l` ASC"), sql)
    }
}
