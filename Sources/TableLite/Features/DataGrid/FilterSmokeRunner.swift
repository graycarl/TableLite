import Foundation

/// 过滤器的端到端冒烟验证（隐藏参数 `--filter-smoke`）。
///
/// 覆盖：行过滤器 SQL 正确性、`LIKE` 通配符转义、Raw 模式、多条件叠加、
/// 列显隐不影响 SQL、错误处理。用真实 MySQL 校验生成语句确实能查到预期行。
///
/// 用法（环境变量与 `scripts/smoke/run.sh` 一致）：
///
///     MYSQL_HOST=127.0.0.1 MYSQL_PORT=13306 MYSQL_USER=root MYSQL_PASSWORD=tablelite \
///       TableLite.app/Contents/MacOS/TableLite --filter-smoke
@MainActor
enum FilterSmokeRunner {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--filter-smoke")
    }

    static func scheduleIfRequested() {
        guard isRequested else { return }
        Task { @MainActor in
            let code = await runAll()
            fflush(stdout)
            exit(code == 0 ? 0 : 1)
        }
    }

    private static func runAll() async -> Int {
        let config = FilterSmokeConfig.fromEnvironment()
        print("== TableLite 过滤冒烟（行过滤器 / 条件叠加 / Raw / 列显示）==")
        print("   目标：\(config.user)@\(config.host):\(config.port)/\(config.database)\n")

        let environment = AppEnvironment.makeFallback()
        environment.preferences.rememberFilters = false
        environment.preferences.rememberColumnLayout = false

        let connection = Connection(
            id: UUID(),
            name: "filter-smoke",
            mysql: MySQLConfig(
                host: config.host,
                port: config.port,
                user: config.user,
                database: config.database,
                keepAlive: false
            ),
            ssh: SSHConfig()
        )
        do {
            _ = try await environment.sessionManager.connect(connection, password: config.password)
        } catch {
            print("      连接失败：\(error)")
            return 1
        }
        guard let session = environment.sessionManager.session(id: connection.id) else {
            print("      找不到会话")
            return 1
        }
        if session.unresolvedDatabase == config.database {
            do {
                _ = try await session.execute("CREATE DATABASE IF NOT EXISTS `\(config.database)`", recordHistory: false)
                _ = try await session.execute("USE `\(config.database)`", recordHistory: false)
                await session.selectDatabase(config.database)
            } catch {
                print("      创建数据库失败：\(error)")
                return 1
            }
        }
        defer { Task { await environment.sessionManager.disconnect(id: connection.id) } }

        do {
            try await prepare(session)
        } catch {
            print("      准备数据失败：\(error)")
            return 1
        }

        var failures = 0
        var total = 0
        let expected = 8

        func check(_ title: String, _ body: () async throws -> String) async {
            total += 1
            print("[\(total)/\(expected)] \(title)")
            do {
                let detail = try await body()
                print(detail.isEmpty ? "      OK" : "      OK  \(detail)")
            } catch {
                failures += 1
                print("      失败：\(error)")
            }
        }

        await check("包含过滤：name 含「张」→ 2 行") {
            let (viewModel, count) = try await filteredRows(environment, session) { model in
                model.addFilterCondition(column: "name", op: .contains, value: "张")
            }
            guard count == 2 else { throw FilterSmokeFailure("期望 2 行，实得 \(count)") }
            return viewModel.filterError ?? ""
        }

        await check("数值比较：age >= 18 → 5 行（数字不带引号）") {
            let (_, count) = try await filteredRows(environment, session) { model in
                model.addFilterCondition(column: "age", op: .greaterThanOrEqual, value: "18")
            }
            guard count == 5 else { throw FilterSmokeFailure("期望 5 行，实得 \(count)") }
            return ""
        }

        await check("IN 列表：status IN ('draft','published') → 5 行") {
            let (_, count) = try await filteredRows(environment, session) { model in
                model.addFilterCondition(column: "status", op: .inList, value: "draft, published")
            }
            guard count == 5 else { throw FilterSmokeFailure("期望 5 行，实得 \(count)") }
            return ""
        }

        await check("为空：note IS NULL → 2 行") {
            let (_, count) = try await filteredRows(environment, session) { model in
                model.addFilterCondition(column: "note", op: .isNull, value: "")
            }
            guard count == 2 else { throw FilterSmokeFailure("期望 2 行，实得 \(count)") }
            return ""
        }

        await check("LIKE 转义：note 含「50%」只匹配字面量 → 1 行") {
            let (_, count) = try await filteredRows(environment, session) { model in
                model.addFilterCondition(column: "note", op: .contains, value: "50%")
            }
            guard count == 1 else { throw FilterSmokeFailure("期望 1 行（500 不应命中），实得 \(count)") }
            return ""
        }

        await check("OR 组合：name 含「张」OR age = 40 → 3 行") {
            let (_, count) = try await filteredRows(environment, session) { model in
                model.addFilterCondition(column: "name", op: .contains, value: "张")
                model.addFilterCondition(column: "age", op: .equal, value: "40")
                model.setFilterCombination(.any)
            }
            guard count == 3 else { throw FilterSmokeFailure("期望 3 行，实得 \(count)") }
            return ""
        }

        await check("Raw 模式：age BETWEEN 18 AND 30 → 4 行") {
            let (_, count) = try await filteredRows(environment, session) { model in
                model.switchFilterToRawMode()
                model.setRawWhere("age BETWEEN 18 AND 30")
            }
            guard count == 4 else { throw FilterSmokeFailure("期望 4 行，实得 \(count)") }
            return ""
        }

        await check("行条件叠加 + 列显隐不改 SQL") {
            let (viewModel, count) = try await filteredRows(environment, session) { model in
                model.applyColumnVisibility(hidden: ["note"])
                model.addFilterCondition(column: "status", op: .equal, value: "published")
                model.addFilterCondition(column: "age", op: .equal, value: "25")
            }
            guard count == 1 else { throw FilterSmokeFailure("期望 1 行，实得 \(count)") }
            // 两条条件叠加，且隐藏的列仍出现在单元格里（仍被查询）。
            guard viewModel.rows.first?.cells["note"]?.value == .text("500") else {
                throw FilterSmokeFailure("隐藏列 note 仍应被查询到")
            }
            return "status=published AND age=25"
        }

        print("")
        if failures == 0 {
            print("过滤冒烟全部通过（\(total) 项）。")
        } else {
            print("\(failures)/\(total) 项失败。")
        }
        return failures
    }

    // MARK: 准备与工具

    /// 建一张能覆盖各种操作符的表；返回过滤后的 ViewModel 与行数。
    private static func filteredRows(
        _ environment: AppEnvironment,
        _ session: ConnectionSession,
        configure: (TableDataViewModel) -> Void
    ) async throws -> (TableDataViewModel, Int) {
        let database = session.selectedDatabase ?? session.connection.mysql.database
        let tab = session.openTableData(database: database, table: "tl_filter_test", forceNew: true)
        let viewModel = TableDataViewModel(
            session: session,
            tab: tab,
            preferences: environment.preferences,
            clock: environment.clock
        )
        await viewModel.start()
        // 清掉启动时的默认查询状态，避免上一次的过滤残留。
        viewModel.setFilter(FilterState())
        await viewModel.waitForPendingWork()

        configure(viewModel)
        viewModel.applyFilter()
        await viewModel.waitForPendingWork()
        if let error = viewModel.filterError {
            throw FilterSmokeFailure("应用过滤失败：\(error)")
        }
        return (viewModel, viewModel.rows.count)
    }

    private static func prepare(_ session: ConnectionSession) async throws {
        try await exec(session, "DROP TABLE IF EXISTS tl_filter_test")
        try await exec(session, """
            CREATE TABLE tl_filter_test (
              id INT PRIMARY KEY AUTO_INCREMENT,
              name VARCHAR(64),
              status ENUM('draft','published','deleted') DEFAULT 'draft',
              age INT,
              note VARCHAR(64)
            )
            """)
        let rows: [(String, String, Int, String?)] = [
            ("张三", "draft", 20, "hello"),
            ("李四", "published", 30, "world"),
            ("张三", "deleted", 15, nil),
            ("王五", "draft", 18, "50% off"),
            ("赵六", "published", 40, nil),
            ("钱七", "published", 25, "500"),
        ]
        for row in rows {
            let note = row.3.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
            try await exec(
                session,
                "INSERT INTO tl_filter_test (name, status, age, note) VALUES ('\(row.0)', '\(row.1)', \(row.2), \(note))"
            )
        }
    }

    @discardableResult
    private static func exec(_ session: ConnectionSession, _ sql: String) async throws -> MySQLQueryResult {
        let result = try await session.execute(sql, recordHistory: false)
        if let error = result.firstError {
            throw FilterSmokeFailure("\(sql.prefix(60)) → code=\(error.code) \(error.message)")
        }
        return result
    }
}

// MARK: - 配置 / 错误

private struct FilterSmokeConfig: Sendable {
    let host: String
    let port: Int
    let user: String
    let password: String
    let database: String

    static func fromEnvironment() -> FilterSmokeConfig {
        let env = ProcessInfo.processInfo.environment
        return FilterSmokeConfig(
            host: env["MYSQL_HOST"] ?? "127.0.0.1",
            port: Int(env["MYSQL_PORT"] ?? "3306") ?? 3306,
            user: env["MYSQL_USER"] ?? "root",
            password: env["MYSQL_PASSWORD"] ?? "",
            database: env["MYSQL_DATABASE"] ?? "tablelite_smoke"
        )
    }
}

private struct FilterSmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
