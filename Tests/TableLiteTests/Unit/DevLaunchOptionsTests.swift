import XCTest
@testable import TableLite

#if DEBUG
/// Debug 启动参数解析与安全校验（`docs/tech-designs/15-testing.md` §9.1、§9.2）。
///
/// 重点覆盖「拒绝写坏真实数据」这条硬约束，以及每个参数的形式校验。
final class DevLaunchOptionsTests: XCTestCase {

    private let liveRoot = URL(fileURLWithPath: "/Users/tester/Library/Application Support/TableLite")
    private let home = URL(fileURLWithPath: "/Users/tester")

    private func parse(_ arguments: [String]) throws -> DevLaunchOptions {
        try DevLaunchOptions.parse(
            arguments: ["TableLite"] + arguments,
            liveRoot: liveRoot,
            homeDirectory: home
        )
    }

    // MARK: 空参数

    func testNoDevFlagsIsEmpty() throws {
        let options = try parse(["--bench-scroll", "wide_test"])
        XCTAssertTrue(options.isEmpty)
    }

    // MARK: 数据目录

    func testAcceptsCustomDataDirectory() throws {
        let options = try parse(["--dev-data-dir", "/tmp/tablelite-dev"])
        XCTAssertEqual(options.dataDirectory?.path, "/tmp/tablelite-dev")
        // 只给数据目录时必须自动补 dev suite：否则偏好会写回真实域。
        XCTAssertEqual(options.defaultsSuite, "com.graycarl.tablelite.dev")
        XCTAssertFalse(options.isEmpty)
    }

    func testKeepsExplicitDefaultsSuite() throws {
        let options = try parse([
            "--dev-data-dir", "/tmp/tablelite-dev",
            "--dev-defaults-suite", "com.example.devprofile"
        ])
        XCTAssertEqual(options.defaultsSuite, "com.example.devprofile")
    }

    func testRejectsLiveRootAndAncestors() {
        for path in [
            "/Users/tester/Library/Application Support/TableLite",
            "/Users/tester/Library/Application Support",
            "/Users/tester",
            "/Users",
            "/",
            "/Users/tester/",
            // 真实根的后代同样在真实数据区里。
            "/Users/tester/Library/Application Support/TableLite/dev",
            // `..` 规范化后指回真实根。
            "/Users/tester/Library/Application Support/TableLite/../TableLite"
        ] {
            XCTAssertThrowsError(try parse(["--dev-data-dir", path]), path) { error in
                guard case DevLaunchError.dangerousDataDirectory = error else {
                    return XCTFail("\(path) 应被拒绝，实际 \(error)")
                }
            }
        }
    }

    func testRejectsEmptyDataDirectory() {
        XCTAssertThrowsError(try parse(["--dev-data-dir", "  "]))
    }

    // MARK: 偏好 suite

    func testRejectsMainDefaultsSuite() {
        XCTAssertThrowsError(try parse(["--dev-defaults-suite", "com.graycarl.tablelite"]))
        XCTAssertThrowsError(try parse(["--dev-defaults-suite", ""]))
    }

    func testAcceptsDevDefaultsSuite() throws {
        let options = try parse(["--dev-defaults-suite", "com.graycarl.tablelite.dev"])
        XCTAssertEqual(options.defaultsSuite, "com.graycarl.tablelite.dev")
    }

    // MARK: 连接 / 表

    func testParsesConnection() throws {
        let options = try parse(["--dev-connect", "127.0.0.1:13307/tablelite_dev"])
        XCTAssertEqual(options.connection, .init(host: "127.0.0.1", port: 13307, database: "tablelite_dev"))
    }

    func testConnectionDefaultsPort() throws {
        let options = try parse(["--dev-connect", "db.local/app"])
        XCTAssertEqual(options.connection?.port, 3306)
        XCTAssertEqual(options.connection?.database, "app")
    }

    func testRejectsInvalidConnection() {
        XCTAssertThrowsError(try parse(["--dev-connect", "/db"]))
        XCTAssertThrowsError(try parse(["--dev-connect", "host:0/db"]))
        XCTAssertThrowsError(try parse(["--dev-connect", "host:70000/db"]))
    }

    func testParsesTableWithAndWithoutDatabase() throws {
        XCTAssertEqual(
            try parse(["--dev-open-table", "tablelite_dev.wide_test"]).openTable,
            .init(database: "tablelite_dev", table: "wide_test")
        )
        XCTAssertEqual(try parse(["--dev-open-table", "wide_test"]).openTable, .init(database: nil, table: "wide_test"))
        XCTAssertThrowsError(try parse(["--dev-open-table", "db."]))
        XCTAssertThrowsError(try parse(["--dev-open-table", ".t"]))
    }

    // MARK: 单元格

    func testParsesSelectCell() throws {
        let options = try parse(["--dev-select-cell", "3,status"])
        XCTAssertEqual(options.selectCell, .init(row: 3, column: "status"))
    }

    func testRejectsInvalidCell() {
        XCTAssertThrowsError(try parse(["--dev-select-cell", "0,status"]))
        XCTAssertThrowsError(try parse(["--dev-select-cell", "3,"]))
        XCTAssertThrowsError(try parse(["--dev-select-cell", "3"]))
        XCTAssertThrowsError(try parse(["--dev-select-cell", "x,status"]))
    }

    func testParsesRepeatedEdits() throws {
        let options = try parse([
            "--dev-edit-cell", "1,status=paid",
            "--dev-edit-cell", "2,note=含 = 等号",
            "--dev-edit-cell", "3,note=",
            "--dev-edit-cell", "4,note=NULL",
            "--dev-edit-cell", "5,note=null"
        ])
        XCTAssertEqual(options.editCells.count, 5)
        XCTAssertEqual(options.editCells[0].value, .text("paid"))
        XCTAssertEqual(options.editCells[1].value, .text("含 = 等号"))
        XCTAssertEqual(options.editCells[2].value, .text(""))
        XCTAssertEqual(options.editCells[3].value, .null)
        XCTAssertEqual(options.editCells[4].value, .null)
    }

    // MARK: 外观 / 尺寸 / 行数

    func testParsesAppearanceAndWindowSize() throws {
        let options = try parse(["--dev-appearance", "dark", "--dev-window-size", "1440x900"])
        XCTAssertEqual(options.appearance, .dark)
        XCTAssertEqual(options.windowSize, CGSize(width: 1440, height: 900))
    }

    func testRejectsInvalidAppearanceAndWindowSize() {
        XCTAssertThrowsError(try parse(["--dev-appearance", "blue"]))
        XCTAssertThrowsError(try parse(["--dev-window-size", "1440"]))
        XCTAssertThrowsError(try parse(["--dev-window-size", "100x100"]))
    }

    func testRowLimitRange() throws {
        XCTAssertEqual(try parse(["--dev-row-limit", "1000"]).rowLimit, 1000)
        XCTAssertThrowsError(try parse(["--dev-row-limit", "0"]))
        XCTAssertThrowsError(try parse(["--dev-row-limit", "\(RowLimit.maximum + 1)"]))
    }

    // MARK: 标签 / 场景

    func testParsesOpenTab() throws {
        for target in ["query", "history", "console", "structure", "definition"] {
            XCTAssertEqual(try parse(["--dev-open-tab", target]).openTab?.rawValue, target)
        }
        XCTAssertThrowsError(try parse(["--dev-open-tab", "bogus"]))
    }

    func testRejectsUnknownScenario() {
        XCTAssertThrowsError(try parse(["--dev-scenario", "pending-changes"])) { error in
            guard case DevLaunchError.unknownScenario("pending-changes") = error else {
                return XCTFail("应报未知场景，实际 \(error)")
            }
        }
    }

    func testRejectsConflictingModes() {
        for flag in ["--bench-scroll", "--smoke", "--query-smoke", "--filter-smoke", "--edit-smoke"] {
            XCTAssertThrowsError(try parse([flag, "x", "--dev-open-table", "db.t"]), flag) { error in
                guard case DevLaunchError.conflictingMode = error else {
                    return XCTFail("\(flag) 应报互斥，实际 \(error)")
                }
            }
        }
    }

    func testParsesIPv6Connection() throws {
        XCTAssertEqual(
            try parse(["--dev-connect", "[::1]:13307/tablelite_dev"]).connection,
            .init(host: "::1", port: 13307, database: "tablelite_dev")
        )
    }

    // MARK: 参数拼写

    func testRejectsUnknownDevFlag() {
        XCTAssertThrowsError(try parse(["--dev-open-tabel", "x"])) { error in
            guard case DevLaunchError.unknownFlag("--dev-open-tabel") = error else {
                return XCTFail("应报未知参数，实际 \(error)")
            }
        }
    }

    func testRejectsMissingValue() {
        XCTAssertThrowsError(try parse(["--dev-open-table"])) { error in
            guard case DevLaunchError.missingValue("--dev-open-table") = error else {
                return XCTFail("应报缺值，实际 \(error)")
            }
        }
    }

    // MARK: ready 文件

    func testParsesReadyFile() throws {
        XCTAssertEqual(try parse(["--dev-ready-file", "/tmp/ready.json"]).readyFile?.path, "/tmp/ready.json")
    }

    func testIgnoresNonDevArguments() throws {
        let options = try parse(["--some-other-flag", "value", "--dev-open-table", "db.t"])
        XCTAssertEqual(options.openTable?.table, "t")
        XCTAssertEqual(options.openTable?.database, "db")
    }
}
#endif
