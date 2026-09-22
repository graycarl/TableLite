import XCTest
@testable import TableLite

/// 导出：流式写文件、取消保留 `.partial`、LIMIT 剥离、导出计划。
///
/// 见 `specs/08-import-export.md` §1、`docs/tech-designs/11-schema-and-import-export.md` §3。
final class CSVExportTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteCSVExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Sink：特殊字符 / NULL / 二进制

    func testSinkWritesSpecialCharactersNullAndBinary() throws {
        let target = directory.appendingPathComponent("out.csv")
        let sink = try CSVExportSink(targetURL: target, options: .default)
        try sink.writeHeaderIfNeeded(["id", "name", "note"])
        try sink.append([.text("1"), .text("a,b"), .null])
        try sink.append([.text("2"), .text("say \"hi\""), .binary(Data([0xDE, 0xAD]))])
        try sink.append([.text("3"), .text("line1\nline2"), .null])
        try sink.finish()

        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(
            text,
            "id,name,note\n1,\"a,b\",\n2,\"say \"\"hi\"\"\",0xDEAD\n3,\"line1\nline2\",\n"
        )
        XCTAssertEqual(sink.snapshot().rowCount, 3)
    }

    func testSinkNullLiteralAndCRLFAndBOM() throws {
        let target = directory.appendingPathComponent("out.csv")
        var options = CSVWriteOptions.default
        options.nullRepresentation = .nullLiteral
        options.lineEnding = .crlf
        options.encoding = .utf8WithBOM
        options.includeHeader = false

        let sink = try CSVExportSink(targetURL: target, options: options)
        try sink.append([.null, .text("x")])
        try sink.finish()

        let data = try Data(contentsOf: target)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        XCTAssertEqual(text, "NULL,x\r\n")
    }

    func testSinkAbortKeepsPartialFile() throws {
        let target = directory.appendingPathComponent("out.csv")
        let sink = try CSVExportSink(targetURL: target, options: .default)
        try sink.writeHeaderIfNeeded(["a"])
        try sink.append([.text("1")])
        sink.abort()

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sink.partialURL.path))
        let text = try String(contentsOf: sink.partialURL, encoding: .utf8)
        XCTAssertEqual(text, "a\n1\n")
    }

    func testSinkRejectsMissingDirectory() {
        let target = directory.appendingPathComponent("missing").appendingPathComponent("out.csv")
        XCTAssertThrowsError(try CSVExportSink(targetURL: target, options: .default))
    }

    // MARK: - Sink：大数据量缓冲刷盘（内存平稳）

    func testSinkFlushesIncrementallyForLargeData() throws {
        let target = directory.appendingPathComponent("large.csv")
        let sink = try CSVExportSink(targetURL: target, options: .default)
        try sink.writeHeaderIfNeeded(["id", "name", "payload"])

        let rowCount = 50_000
        for index in 0..<rowCount {
            try sink.append([.text(String(index)), .text("name\(index)"), .null])
        }
        try sink.finish()

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.rowCount, rowCount)
        // 内容远超 256 KB 阈值，必须发生多次刷盘，而不是攒到最后一次性写。
        XCTAssertGreaterThan(snapshot.flushCount, 1)

        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, rowCount + 1)
    }

    // MARK: - 引擎：端到端（FakeMySQLSession）

    func testEngineStreamsRowsToAtomicTarget() async throws {
        let mysql = FakeMySQLSession()
        await mysql.setResponses([
            ("SELECT", .single(columns: ["id", "name"], rows: [["1", "张三"], ["2", "李四"], ["3", "王五"]])),
        ])
        let target = directory.appendingPathComponent("rows.csv")
        let sink = try CSVExportSink(targetURL: target, options: .default)
        let plan = ExportPlan(
            sql: "SELECT `id`, `name` FROM `app_dev`.`users`",
            database: "app_dev",
            header: ["id", "name"],
            columns: [
                ColumnInfo(name: "id", fieldType: .long),
                ColumnInfo(name: "name", fieldType: .varString, charsetNumber: 33),
            ],
            sourceTitle: "app_dev.users",
            sourceDetail: "整张表"
        )

        let summary = await CSVExportEngine.run(
            plan: plan,
            sink: sink,
            control: ExportControl(),
            source: .raw(mysql)
        )

        XCTAssertTrue(summary.isSuccess, summary.failureMessage ?? "")
        XCTAssertEqual(summary.rowCount, 3)
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(text, "id,name\n1,张三\n2,李四\n3,王五\n")
    }

    func testEngineAbortsWhenCancelled() async throws {
        let mysql = FakeMySQLSession()
        await mysql.setResponses([
            ("SELECT", .single(columns: ["id"], rows: [["1"], ["2"]])),
        ])
        let target = directory.appendingPathComponent("cancel.csv")
        let sink = try CSVExportSink(targetURL: target, options: .default)
        let control = ExportControl()
        control.cancel()
        let plan = ExportPlan(
            sql: "SELECT 1",
            header: ["id"],
            columns: [ColumnInfo(name: "id", fieldType: .long)],
            sourceTitle: "t",
            sourceDetail: "d"
        )

        let summary = await CSVExportEngine.run(
            plan: plan,
            sink: sink,
            control: control,
            source: .raw(mysql)
        )

        XCTAssertTrue(summary.wasCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sink.partialURL.path))
    }

    // MARK: - LIMIT 剥离

    func testLimitRemovalStripsSimpleLimit() {
        let result = SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM `users` LIMIT 10")
        XCTAssertTrue(result.didStrip)
        XCTAssertEqual(result.sql, "SELECT * FROM `users`")
    }

    func testLimitRemovalStripsOffsetForms() {
        XCTAssertEqual(
            SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM t LIMIT 5, 10").sql,
            "SELECT * FROM t"
        )
        XCTAssertEqual(
            SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM t LIMIT 10 OFFSET 5").sql,
            "SELECT * FROM t"
        )
        XCTAssertEqual(
            SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM t LIMIT 10;").sql,
            "SELECT * FROM t;"
        )
    }

    func testLimitRemovalKeepsSqlWhenAbsent() {
        let result = SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM t")
        XCTAssertEqual(result.outcome, .absent)
        XCTAssertEqual(result.sql, "SELECT * FROM t")
    }

    func testLimitRemovalIgnoresLimitInStringAndComment() {
        XCTAssertEqual(
            SQLLimitRemoval.removingTopLevelLimit("SELECT 'LIMIT 10' FROM t").outcome,
            .absent
        )
        XCTAssertEqual(
            SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM t -- LIMIT 10").outcome,
            .absent
        )
    }

    func testLimitRemovalUncertainForSubqueryAndUnion() {
        XCTAssertEqual(
            SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM (SELECT * FROM t LIMIT 5) x").outcome,
            .uncertain(reason: .subqueryLimit)
        )
        XCTAssertEqual(
            SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM a LIMIT 10 UNION SELECT * FROM b").outcome,
            .uncertain(reason: .union)
        )
    }

    func testLimitRemovalNoteMentionsActualRowsWhenUncertain() {
        let result = SQLLimitRemoval.removingTopLevelLimit("SELECT * FROM (SELECT * FROM t LIMIT 5) x")
        XCTAssertNotNil(result.note)
        XCTAssertTrue(result.note?.contains("实际返回") ?? false)
    }

    // MARK: - 导出计划

    func testPlannerQueryUsesStrippedSql() {
        let plan = ExportQueryPlanner.planQuery(sql: "SELECT * FROM t LIMIT 3", description: "查询 1")
        XCTAssertEqual(plan.sql, "SELECT * FROM t")
        XCTAssertNil(plan.header)
        XCTAssertNotNil(plan.limitNote)
    }

    func testPlannerTableBuildsSelectForExport() {
        let columns = [
            TestSupport.column("id", type: .long, flags: ColumnFlag.primaryKey, charset: 63),
            TestSupport.column("name", type: .varString),
        ]
        let plan = ExportQueryPlanner.planTable(
            database: "app_dev",
            table: "users",
            columns: columns,
            primaryKeyColumns: ["id"],
            filterClause: "`status` = 'published'",
            sourceDetail: "整张表"
        )
        XCTAssertTrue(plan.sql.contains("FROM `app_dev`.`users`"))
        XCTAssertTrue(plan.sql.contains("WHERE `status` = 'published'"))
        XCTAssertFalse(plan.sql.contains("LIMIT"))
        XCTAssertEqual(plan.header, ["id", "name"])
    }

    // MARK: - 导出源说明（`specs/08-import-export.md` §1）

    func testFilteredSourceDetailShowsRealConditionAndEstimate() {
        let source = ExportSource.filteredTable(
            database: "app_dev",
            table: "articles",
            filterClause: "`status` = 'published'",
            filterSummary: "`status` = 'published'",
            rowCountEstimate: 12_480
        )
        XCTAssertEqual(
            source.detailText(rowCountEstimate: nil),
            "应用了过滤条件：`status` = 'published'，共约 12,480 行"
        )
    }

    func testFilteredSourceDetailFallsBackToPassedEstimate() {
        let source = ExportSource.filteredTable(
            database: "app_dev",
            table: "articles",
            filterClause: "1 = 1",
            filterSummary: "1 = 1",
            rowCountEstimate: nil
        )
        XCTAssertEqual(source.detailText(rowCountEstimate: 7), "应用了过滤条件：1 = 1，共约 7 行")
    }

    func testSelectedRowsSourceDetailShowsRowCount() {
        let source = ExportSource.selectedRows(
            database: "app_dev",
            table: "users",
            whereClause: "(`id` = 1)",
            rowCount: 3
        )
        XCTAssertEqual(source.title, "app_dev.users（选中行）")
        XCTAssertEqual(source.detailText(rowCountEstimate: nil), "仅导出选中的 3 行")
    }

    func testQueryResultSourceDetail() {
        let source = ExportSource.queryResult(sql: "SELECT 1", description: "结果 1")
        XCTAssertEqual(source.title, "结果 1")
        XCTAssertEqual(source.detailText(rowCountEstimate: nil), "该查询结果集的全部行")
    }

    // MARK: - 日期格式（`specs/08-import-export.md` §1）

    func testDateFormatResolvedPatternOnlyForCustom() {
        XCTAssertNil(CSVDateFormat.raw.resolvedPattern)
        XCTAssertEqual(
            CSVDateFormat(style: .custom, customPattern: "yyyy/MM/dd").resolvedPattern,
            "yyyy/MM/dd"
        )
        XCTAssertNil(CSVDateFormat(style: .custom, customPattern: "  ").resolvedPattern)
    }

    func testDateFormatterConvertsDateAndDateTimeColumns() {
        let date = ColumnInfo(name: "d", fieldType: .date)
        let datetime = ColumnInfo(name: "dt", fieldType: .datetime)
        XCTAssertEqual(
            CSVDateFormatter.formatted(.text("2025-01-02"), column: date, pattern: "yyyy/MM/dd"),
            .text("2025/01/02")
        )
        XCTAssertEqual(
            CSVDateFormatter.formatted(.text("2025-01-02 11:30:45"), column: datetime, pattern: "yyyy-MM-dd HH:mm"),
            .text("2025-01-02 11:30")
        )
        // 带小数秒的 DATETIME 也要能解析。
        XCTAssertEqual(
            CSVDateFormatter.formatted(.text("2025-01-02 11:30:45.123456"), column: datetime, pattern: "yyyy-MM-dd"),
            .text("2025-01-02")
        )
    }

    func testDateFormatterLeavesNonDateAndUnparseableValues() {
        let text = ColumnInfo(name: "name", fieldType: .varString)
        XCTAssertEqual(
            CSVDateFormatter.formatted(.text("2025-01-02"), column: text, pattern: "yyyy"),
            .text("2025-01-02")
        )
        let date = ColumnInfo(name: "d", fieldType: .date)
        XCTAssertEqual(
            CSVDateFormatter.formatted(.text("不是日期"), column: date, pattern: "yyyy"),
            .text("不是日期")
        )
        XCTAssertEqual(
            CSVDateFormatter.formatted(.null, column: date, pattern: "yyyy"),
            .null
        )
    }
}
