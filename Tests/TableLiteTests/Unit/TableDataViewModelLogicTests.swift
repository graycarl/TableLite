import XCTest
@testable import TableLite

/// `TableDataViewModelLogic` 的纯函数边界。
/// 覆盖 docs/tech-designs/07-data-grid.md §3.1/§7、docs/tech-designs/14-row-inspector.md §6、
/// specs/03-data-browsing.md §2、specs/04-data-editing.md §5。
final class TableDataViewModelLogicTests: XCTestCase {

    // MARK: - 大字段合计阈值（8 MB）

    func testShouldAutoLoadAtOrBelowLimit() {
        XCTAssertTrue(TableDataViewModelLogic.shouldAutoLoadFullValues(totalBytes: 0))
        XCTAssertTrue(TableDataViewModelLogic.shouldAutoLoadFullValues(
            totalBytes: TableDataViewModelLogic.autoLoadByteLimit
        ))
    }

    func testShouldNotAutoLoadAboveLimit() {
        XCTAssertFalse(TableDataViewModelLogic.shouldAutoLoadFullValues(
            totalBytes: TableDataViewModelLogic.autoLoadByteLimit + 1
        ))
    }

    // MARK: - 复制行：清空自增列、跳过生成列

    private func column(_ name: String,
                        dataType: String = "int",
                        pk: Bool = false,
                        autoIncrement: Bool = false,
                        generated: Bool = false) -> TableColumn {
        TableColumn(
            name: name,
            dataType: dataType,
            rawTypeText: dataType,
            isPrimaryKey: pk,
            isAutoIncrement: autoIncrement,
            isGenerated: generated
        )
    }

    func testDuplicateDropsAutoIncrementAndGenerated() {
        let columns = [
            column("id", pk: true, autoIncrement: true),
            column("name", dataType: "varchar"),
            column("total", dataType: "int", generated: true),
        ]
        let values: [String: CellValue] = [
            "id": .text("42"),
            "name": .text("张三"),
            "total": .text("100"),
        ]

        let copied = TableDataViewModelLogic.duplicateColumnValues(columns: columns, values: values)

        XCTAssertNil(copied["id"], "自增主键列必须清空")
        XCTAssertNil(copied["total"], "生成列不能出现在 INSERT 里")
        XCTAssertEqual(copied["name"], .text("张三"))
    }

    func testDuplicateKeepsNonAutoPrimaryKey() {
        let columns = [
            column("code", dataType: "varchar", pk: true),
            column("name", dataType: "varchar"),
        ]
        let copied = TableDataViewModelLogic.duplicateColumnValues(
            columns: columns,
            values: ["code": .text("A1"), "name": .text("李四")]
        )

        XCTAssertEqual(copied["code"], .text("A1"), "非自增主键列按规范保留")
        XCTAssertEqual(copied["name"], .text("李四"))
    }

    // MARK: - 行区间文案

    func testRowRangeText() {
        XCTAssertEqual(
            TableDataViewModelLogic.rowRangeText(pageIndex: 0, pageSize: 300, rowCount: 300),
            "行 1–300"
        )
        XCTAssertEqual(
            TableDataViewModelLogic.rowRangeText(pageIndex: 1, pageSize: 300, rowCount: 300),
            "行 301–600"
        )
        XCTAssertEqual(
            TableDataViewModelLogic.rowRangeText(pageIndex: 0, pageSize: 300, rowCount: 0),
            "行 0"
        )
        XCTAssertEqual(
            TableDataViewModelLogic.rowRangeText(pageIndex: 0, pageSize: 1000, rowCount: 1000),
            "行 1–1,000"
        )
    }

    // MARK: - 行数文案

    func testRowCountText() {
        XCTAssertEqual(TableDataViewModelLogic.rowCountText(estimate: nil, isExact: false), "行数未知")
        XCTAssertEqual(TableDataViewModelLogic.rowCountText(estimate: 12_480, isExact: false), "约 12,480 行")
        XCTAssertEqual(TableDataViewModelLogic.rowCountText(estimate: 12_480, isExact: true), "12,480 行")
        XCTAssertEqual(
            TableDataViewModelLogic.rowCountText(estimate: 0, isExact: false),
            "约 0 行（估算不可靠）"
        )
        XCTAssertEqual(TableDataViewModelLogic.rowCountText(estimate: 0, isExact: true), "0 行")
    }

    // MARK: - 数字分组

    func testGroupedDigits() {
        XCTAssertEqual(TableDataViewModelLogic.groupedDigits(0), "0")
        XCTAssertEqual(TableDataViewModelLogic.groupedDigits(7), "7")
        XCTAssertEqual(TableDataViewModelLogic.groupedDigits(999), "999")
        XCTAssertEqual(TableDataViewModelLogic.groupedDigits(1_000), "1,000")
        XCTAssertEqual(TableDataViewModelLogic.groupedDigits(12_480), "12,480")
        XCTAssertEqual(TableDataViewModelLogic.groupedDigits(1_000_000), "1,000,000")
        XCTAssertEqual(TableDataViewModelLogic.groupedDigits(-12_480), "-12,480")
    }

    // MARK: - 深翻页提示

    func testDeepOffset() {
        XCTAssertFalse(TableDataViewModelLogic.isDeepOffset(pageIndex: 0, pageSize: 300))
        XCTAssertFalse(TableDataViewModelLogic.isDeepOffset(pageIndex: 333, pageSize: 300))
        XCTAssertTrue(TableDataViewModelLogic.isDeepOffset(pageIndex: 334, pageSize: 300))
    }
}
