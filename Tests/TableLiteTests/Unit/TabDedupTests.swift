import XCTest
@testable import TableLite

/// 标签去重规则。见 `docs/tech-designs/06-ui-layer.md` §3 与
/// `specs/02-workspace.md` §6。
///
/// 规则全部抽在 `TabKind` 的纯函数上，这里只测纯逻辑：
/// - 表数据 / 表结构 / 对象定义按 schema + 名称精确匹配复用；
/// - 查询总是新建；
/// - 历史 / Console Log 各只允许一个；
/// - 不同目标不复用。
final class TabDedupTests: XCTestCase {

    private let users = TableRef(database: "app_dev", table: "users")
    private let orders = TableRef(database: "app_dev", table: "orders")

    // MARK: 表数据复用

    func testTableDataReusesExistingTab() {
        let tabs: [TabKind] = [.tableData(users), .tableStructure(orders)]
        XCTAssertEqual(TabKind.existingTab(for: .tableData(users), in: tabs), 0)
    }

    func testTableDataDoesNotReuseOtherTable() {
        let tabs: [TabKind] = [.tableData(users)]
        XCTAssertNil(TabKind.existingTab(for: .tableData(orders), in: tabs))
    }

    func testTableDataDoesNotReuseAcrossDatabases() {
        let tabs: [TabKind] = [.tableData(users)]
        let otherDatabase = TableRef(database: "app_staging", table: "users")
        XCTAssertNil(TabKind.existingTab(for: .tableData(otherDatabase), in: tabs))
    }

    // MARK: 表结构复用

    func testTableStructureReusesExistingTab() {
        let tabs: [TabKind] = [.tableStructure(users), .tableStructure(orders)]
        XCTAssertEqual(TabKind.existingTab(for: .tableStructure(orders), in: tabs), 1)
    }

    func testTableDataAndTableStructureAreDifferentKinds() {
        let tabs: [TabKind] = [.tableData(users)]
        XCTAssertNil(TabKind.existingTab(for: .tableStructure(users), in: tabs))
    }

    // MARK: 对象定义复用

    func testObjectDefinitionReusesExistingTab() {
        let tabs: [TabKind] = [.objectDefinition(users, .view)]
        XCTAssertEqual(TabKind.existingTab(for: .objectDefinition(users, .view), in: tabs), 0)
    }

    func testObjectDefinitionDoesNotReuseDifferentKind() {
        let tabs: [TabKind] = [.objectDefinition(users, .view)]
        XCTAssertNil(TabKind.existingTab(for: .objectDefinition(users, .table), in: tabs))
    }

    // MARK: 查询总是新建

    func testQueryNeverReuses() {
        let draftID = UUID()
        let tabs: [TabKind] = [.query(draftID)]
        XCTAssertNil(TabKind.existingTab(for: .query(draftID), in: tabs))
        XCTAssertNil(TabKind.existingTab(for: .query(UUID()), in: tabs))
    }

    func testQueryDoesNotReuseMetadataTabWithSameIdentityConcept() {
        let tabs: [TabKind] = [.tableData(users)]
        XCTAssertNil(TabKind.existingTab(for: .query(UUID()), in: tabs))
    }

    // MARK: 历史 / Console Log 单例

    func testHistoryIsSingleton() {
        let tabs: [TabKind] = [.tableData(users), .history]
        XCTAssertEqual(TabKind.existingTab(for: .history, in: tabs), 1)
    }

    func testConsoleLogIsSingleton() {
        let tabs: [TabKind] = [.consoleLog, .history]
        XCTAssertEqual(TabKind.existingTab(for: .consoleLog, in: tabs), 0)
    }

    func testHistoryAndConsoleLogAreDistinct() {
        let tabs: [TabKind] = [.history]
        XCTAssertNil(TabKind.existingTab(for: .consoleLog, in: tabs))
        XCTAssertNil(TabKind.existingTab(for: .history, in: [.consoleLog]))
    }

    // MARK: 空列表

    func testNoTabsMeansNoReuse() {
        XCTAssertNil(TabKind.existingTab(for: .tableData(users), in: []))
        XCTAssertNil(TabKind.existingTab(for: .history, in: []))
    }

    // MARK: matches 本身

    func testMatchesIsSymmetricForReusableKinds() {
        XCTAssertTrue(TabKind.tableData(users).matches(.tableData(users)))
        XCTAssertFalse(TabKind.tableData(users).matches(.tableData(orders)))
        XCTAssertFalse(TabKind.tableData(users).matches(.tableStructure(users)))
    }

    func testQueryMatchesNothing() {
        let draftID = UUID()
        XCTAssertFalse(TabKind.query(draftID).matches(.query(draftID)))
        XCTAssertFalse(TabKind.query(draftID).matches(.tableData(users)))
    }
}
