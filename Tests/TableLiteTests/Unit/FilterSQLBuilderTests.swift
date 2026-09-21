import XCTest
@testable import TableLite

/// 过滤器 SQL 生成边界。见 docs/tech-designs/09-filtering.md §1.4 §1.5。
final class FilterSQLBuilderTests: XCTestCase {

    private let columns: [TableColumn] = [
        TableColumn(name: "id", dataType: "int", rawTypeText: "int"),
        TableColumn(name: "name", dataType: "varchar", rawTypeText: "varchar(255)"),
        TableColumn(name: "age", dataType: "int", rawTypeText: "int"),
    ]

    private func condition(
        _ column: String,
        _ op: FilterOperator,
        _ value: String = "",
        second: String = "",
        enabled: Bool = true
    ) -> FilterCondition {
        FilterCondition(enabled: enabled, column: column, op: op, value: value, secondValue: second)
    }

    private func build(
        _ conditions: [FilterCondition],
        logic: FilterLogic = .all
    ) -> FilterSQLBuilder.Result {
        FilterSQLBuilder.build(
            FilterSet(conditions: conditions, logic: logic),
            columns: columns,
            using: .conservative
        )
    }

    // MARK: 基本比较

    func testTextEqual() {
        let result = build([condition("name", .equal, "Alice")])
        XCTAssertEqual(result.sql, "(`name` = 'Alice')")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testAndJoin() {
        let result = build([
            condition("name", .equal, "Alice"),
            condition("age", .equal, "18"),
        ])
        XCTAssertEqual(result.sql, "(`name` = 'Alice') AND (`age` = 18)")
    }

    func testOrJoin() {
        let result = build([
            condition("age", .lessThan, "18"),
            condition("age", .greaterThan, "60"),
        ], logic: .any)
        XCTAssertEqual(result.sql, "(`age` < 18) OR (`age` > 60)")
    }

    func testComparisonOperators() {
        XCTAssertEqual(build([condition("age", .notEqual, "1")]).sql, "(`age` <> 1)")
        XCTAssertEqual(build([condition("age", .greaterThanOrEqual, "1")]).sql, "(`age` >= 1)")
        XCTAssertEqual(build([condition("age", .lessThanOrEqual, "1")]).sql, "(`age` <= 1)")
    }

    // MARK: 数值列引号

    func testNumericColumnStrictNumberUnquoted() {
        XCTAssertEqual(build([condition("age", .equal, "18")]).sql, "(`age` = 18)")
    }

    func testNumericColumnNonNumericValueQuoted() {
        XCTAssertEqual(build([condition("age", .equal, "abc")]).sql, "(`age` = 'abc')")
        XCTAssertEqual(build([condition("age", .equal, "1e5")]).sql, "(`age` = '1e5')")
    }

    // MARK: LIKE

    func testContainsEscapesLikeAndAppendsEscapeClause() {
        let result = build([condition("name", .contains, "50%")])
        // pattern: %50\%% → 经 literalizer 再次转义反斜杠 → '%50\\%%'
        XCTAssertEqual(result.sql, #"(`name` LIKE '%50\\%%' ESCAPE '\\')"#)
    }

    func testBeginsWithPattern() {
        XCTAssertEqual(build([condition("name", .beginsWith, "ab")]).sql,
                       #"(`name` LIKE 'ab%' ESCAPE '\\')"#)
    }

    func testNotContainsPattern() {
        XCTAssertEqual(build([condition("name", .notContains, "x")]).sql,
                       #"(`name` NOT LIKE '%x%' ESCAPE '\\')"#)
    }

    func testEndsWithPattern() {
        XCTAssertEqual(build([condition("name", .endsWith, "z")]).sql,
                       #"(`name` LIKE '%z' ESCAPE '\\')"#)
    }

    // MARK: IN / BETWEEN

    func testInListTrimsAndJoins() {
        let result = build([condition("age", .inList, "1, 2, 3")])
        XCTAssertEqual(result.sql, "(`age` IN (1, 2, 3))")
    }

    func testInListWithTextValues() {
        XCTAssertEqual(build([condition("name", .inList, "a, b")]).sql,
                       "(`name` IN ('a', 'b'))")
    }

    func testInListEmptyIsIssueAndSkipped() {
        let cond = condition("age", .inList, " , ")
        let result = build([cond])
        XCTAssertNil(result.sql)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues[0].conditionID, cond.id)
    }

    func testBetween() {
        let result = build([condition("age", .between, "1", second: "10")])
        XCTAssertEqual(result.sql, "(`age` BETWEEN 1 AND 10)")
    }

    func testBetweenMissingSecondValueIsIssue() {
        let result = build([condition("age", .between, "1")])
        XCTAssertNil(result.sql)
        XCTAssertEqual(result.issues.count, 1)
    }

    // MARK: NULL

    func testIsNullAndIsNotNullNeedNoValue() {
        XCTAssertEqual(build([condition("name", .isNull)]).sql, "(`name` IS NULL)")
        XCTAssertEqual(build([condition("name", .isNotNull)]).sql, "(`name` IS NOT NULL)")
    }

    // MARK: 跳过与 issue

    func testEmptyValueIsIssueAndSkipped() {
        let result = build([condition("name", .equal, "   ")])
        XCTAssertNil(result.sql)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("缺少值"))
    }

    func testUnknownColumnIsIssue() {
        let result = build([condition("nope", .equal, "x")])
        XCTAssertNil(result.sql)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("找不到列"))
    }

    func testUnknownColumnDoesNotDropOtherConditions() {
        let result = build([
            condition("name", .equal, "Alice"),
            condition("nope", .equal, "x"),
        ])
        XCTAssertEqual(result.sql, "(`name` = 'Alice')")
        XCTAssertEqual(result.issues.count, 1)
    }

    func testDisabledAndEmptyColumnConditionsAreSkippedSilently() {
        let disabled = build([condition("name", .equal, "Alice", enabled: false)])
        XCTAssertNil(disabled.sql)
        XCTAssertTrue(disabled.issues.isEmpty)

        let emptyColumn = build([condition("", .equal, "Alice")])
        XCTAssertNil(emptyColumn.sql)
        XCTAssertTrue(emptyColumn.issues.isEmpty)
    }

    // MARK: Raw 模式

    func testRawSQLIsTrimmed() {
        let result = FilterSQLBuilder.build(
            FilterSet(rawSQL: "  id > 1  ", useRawSQL: true),
            columns: columns,
            using: .conservative
        )
        XCTAssertEqual(result.sql, "id > 1")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testRawSQLWithSemicolonIsRejected() {
        let result = FilterSQLBuilder.build(
            FilterSet(rawSQL: "id > 1; DROP TABLE t", useRawSQL: true),
            columns: columns,
            using: .conservative
        )
        XCTAssertNil(result.sql)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(result.issues[0].message.contains("分号"))
    }

    func testRawSQLEmptyProducesNothing() {
        let result = FilterSQLBuilder.build(
            FilterSet(rawSQL: "   ", useRawSQL: true),
            columns: columns,
            using: .conservative
        )
        XCTAssertNil(result.sql)
        XCTAssertTrue(result.issues.isEmpty)
    }
}
