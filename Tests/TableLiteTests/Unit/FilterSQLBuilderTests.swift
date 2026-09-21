import XCTest
@testable import TableLite

/// 过滤器 WHERE 生成：LIKE 转义、数字去引号、Raw SQL、列校验。
///
/// 见 `docs/tech-designs/09-filtering.md` §1.4、§1.5。
final class FilterSQLBuilderTests: XCTestCase {

    private let columns: [ColumnInfo] = [
        TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63),
        TestSupport.column("name", type: .varString),
        TestSupport.column("age", type: .long, charset: 63),
    ]

    private func state(
        _ conditions: [FilterCondition],
        combination: FilterCombination = .all
    ) -> FilterState {
        FilterState(conditions: conditions, combination: combination)
    }

    private func condition(
        _ column: String,
        _ op: FilterOperator,
        _ value: String = "",
        second: String = "",
        fieldType: MySQLFieldType? = nil,
        enabled: Bool = true
    ) -> FilterCondition {
        FilterCondition(isEnabled: enabled, column: column, op: op, value: value, secondValue: second, fieldType: fieldType)
    }

    // MARK: 基本条件

    func testEqualOnStringColumnQuotes() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("name", .equal, "a")]),
            columns: columns
        )
        XCTAssertEqual(result.clause, "(`name` = 'a')")
    }

    func testEqualOnNumericColumnUnquotesStrictNumber() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("age", .equal, "42", fieldType: .long)]),
            columns: columns
        )
        XCTAssertEqual(result.clause, "(`age` = 42)")
    }

    func testEqualOnNumericColumnQuotesNonNumber() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("age", .equal, "abc", fieldType: .long)]),
            columns: columns
        )
        XCTAssertEqual(result.clause, "(`age` = 'abc')")
    }

    func testComparisonOperators() throws {
        XCTAssertEqual(
            try FilterSQLBuilder.whereClause(for: state([condition("age", .greaterThanOrEqual, "18", fieldType: .long)]), columns: columns).clause,
            "(`age` >= 18)"
        )
        XCTAssertEqual(
            try FilterSQLBuilder.whereClause(for: state([condition("name", .notEqual, "x")]), columns: columns).clause,
            "(`name` <> 'x')"
        )
    }

    // MARK: LIKE 转义

    func testContainsEscapesPercent() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("name", .contains, "50%")]),
            columns: columns
        )
        XCTAssertEqual(result.clause, "(`name` LIKE '%50\\\\%%' ESCAPE '\\\\')")
    }

    func testContainsEscapesUnderscoreAndBackslash() throws {
        XCTAssertEqual(FilterSQLBuilder.escapeLikePattern("a_b"), "a\\_b")
        XCTAssertEqual(FilterSQLBuilder.escapeLikePattern("a\\b"), "a\\\\b")

        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("name", .contains, "a_b")]),
            columns: columns
        )
        XCTAssertEqual(result.clause, "(`name` LIKE '%a\\\\_b%' ESCAPE '\\\\')")
    }

    func testNotContainsUsesNotLike() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("name", .notContains, "x")]),
            columns: columns
        )
        XCTAssertEqual(result.clause, "(`name` NOT LIKE '%x%' ESCAPE '\\\\')")
    }

    func testBeginsWithAndEndsWith() throws {
        XCTAssertEqual(
            try FilterSQLBuilder.whereClause(for: state([condition("name", .beginsWith, "ab")]), columns: columns).clause,
            "(`name` LIKE 'ab%' ESCAPE '\\\\')"
        )
        XCTAssertEqual(
            try FilterSQLBuilder.whereClause(for: state([condition("name", .endsWith, "ab")]), columns: columns).clause,
            "(`name` LIKE '%ab' ESCAPE '\\\\')"
        )
    }

    // MARK: 区间 / 列表 / 空

    func testBetween() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("age", .between, "18", second: "30", fieldType: .long)]),
            columns: columns
        )
        XCTAssertEqual(result.clause, "(`age` BETWEEN 18 AND 30)")
    }

    func testInList() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("id", .inList, "1, 2, 3", fieldType: .long)]),
            columns: columns
        )
        XCTAssertEqual(result.clause, "(`id` IN (1, 2, 3))")
    }

    func testEmptyInListThrows() {
        XCTAssertThrowsError(
            try FilterSQLBuilder.whereClause(
                for: state([condition("id", .inList, " , , ", fieldType: .long)]),
                columns: columns
            )
        ) { error in
            XCTAssertEqual(error as? FilterBuildError, .emptyInList(column: "id"))
        }
    }

    func testIsNullAndIsNotNull() throws {
        XCTAssertEqual(
            try FilterSQLBuilder.whereClause(for: state([condition("name", .isNull)]), columns: columns).clause,
            "(`name` IS NULL)"
        )
        XCTAssertEqual(
            try FilterSQLBuilder.whereClause(for: state([condition("name", .isNotNull)]), columns: columns).clause,
            "(`name` IS NOT NULL)"
        )
    }

    // MARK: 组合 / 禁用 / 未完成

    func testCombinationKeyword() throws {
        let and = try FilterSQLBuilder.whereClause(
            for: state([condition("name", .equal, "a"), condition("age", .equal, "1", fieldType: .long)]),
            columns: columns
        )
        XCTAssertEqual(and.clause, "(`name` = 'a') AND (`age` = 1)")

        let or = try FilterSQLBuilder.whereClause(
            for: state([condition("name", .equal, "a"), condition("age", .equal, "1", fieldType: .long)], combination: .any),
            columns: columns
        )
        XCTAssertEqual(or.clause, "(`name` = 'a') OR (`age` = 1)")
    }

    func testDisabledConditionIsSkipped() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("name", .equal, "a", enabled: false)]),
            columns: columns
        )
        XCTAssertNil(result.clause)
    }

    func testIncompleteConditionIsSkippedAndReported() throws {
        let incomplete = condition("name", .equal, "")
        let result = try FilterSQLBuilder.whereClause(
            for: state([incomplete, condition("age", .equal, "1", fieldType: .long)]),
            columns: columns
        )
        XCTAssertEqual(result.skippedConditionIDs, [incomplete.id])
        XCTAssertEqual(result.clause, "(`age` = 1)")
    }

    func testOnlyIncompleteConditionProducesNoClause() throws {
        let result = try FilterSQLBuilder.whereClause(
            for: state([condition("name", .contains, "   ")]),
            columns: columns
        )
        XCTAssertNil(result.clause)
        XCTAssertEqual(result.skippedConditionIDs.count, 1)
    }

    // MARK: 列校验

    func testUnknownColumnThrowsWithID() {
        let bad = condition("missing", .equal, "x")
        XCTAssertThrowsError(
            try FilterSQLBuilder.whereClause(for: state([bad]), columns: columns)
        ) { error in
            guard let buildError = error as? FilterBuildError,
                  case .unknownColumns(let names, let ids) = buildError else {
                return XCTFail("期望 unknownColumns，实际 \(error)")
            }
            XCTAssertEqual(names, ["missing"])
            XCTAssertEqual(ids, [bad.id])
        }
    }

    // MARK: Raw SQL 模式

    func testRawModePassesThrough() throws {
        var raw = FilterState()
        raw.isRawMode = true
        raw.rawWhere = "id IN (1,2,3) AND status <> 'deleted'"
        let result = try FilterSQLBuilder.whereClause(for: raw, columns: columns)
        XCTAssertEqual(result.clause, "id IN (1,2,3) AND status <> 'deleted'")
    }

    func testRawModeRejectsSemicolon() {
        var raw = FilterState()
        raw.isRawMode = true
        raw.rawWhere = "id = 1; DROP TABLE t"
        XCTAssertThrowsError(try FilterSQLBuilder.whereClause(for: raw, columns: columns)) { error in
            XCTAssertEqual(error as? FilterBuildError, .rawContainsSemicolon)
        }
    }

    func testRawModeEmptyProducesNoClause() throws {
        var raw = FilterState()
        raw.isRawMode = true
        raw.rawWhere = "   "
        XCTAssertNil(try FilterSQLBuilder.whereClause(for: raw, columns: columns).clause)
    }
}
