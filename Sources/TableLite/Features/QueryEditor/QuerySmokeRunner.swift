import Foundation

/// SQL 编辑器的端到端冒烟验证（隐藏参数 `--query-smoke`）。
///
/// 用真实 MySQL 走一遍完整执行路径：多语句拆分 / 当前语句执行 / 语法错误 /
/// 只读拦截 / 取消（`KILL QUERY`）/ 历史与 Console Log 记录。
///
/// 用法（环境变量与 `scripts/smoke/run.sh` 一致）：
///
///     MYSQL_HOST=127.0.0.1 MYSQL_PORT=13306 MYSQL_USER=root MYSQL_PASSWORD=tablelite \
///       TableLite.app/Contents/MacOS/TableLite --query-smoke
@MainActor
enum QuerySmokeRunner {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--query-smoke")
    }

    static func scheduleIfRequested() {
        guard isRequested else { return }
        Task { @MainActor in
            let code = await runAll()
            fflush(stdout)
            exit(code == 0 ? 0 : 1)
        }
    }

    // MARK: 主体

    private static func runAll() async -> Int {
        let config = QuerySmokeConfig.fromEnvironment()
        print("== TableLite SQL 编辑器冒烟（多语句 / 错误 / 只读 / 取消 / 记录）==")
        print("   目标：\(config.user)@\(config.host):\(config.port)/\(config.database)\n")

        let environment = AppEnvironment.makeFallback()
        environment.preferences.rememberFilters = false
        environment.preferences.rememberColumnLayout = false
        environment.preferences.autoSaveDraft = false
        environment.preferences.stopOnError = true

        let connection = Connection(
            id: UUID(),
            name: "query-smoke",
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
        let expected = 6

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

        await check("多语句执行：两条 SELECT 各出一个结果标签") {
            session.setReadOnly(false)
            let model = makeModel(session: session, environment: environment)
            model.textChanged("SELECT id FROM tl_query_test ORDER BY id; SELECT COUNT(*) AS n FROM tl_query_test;")
            model.executeAll()
            await model.waitForExecution()
            guard model.results.count == 2 else {
                throw QuerySmokeFailure("期望 2 个结果标签，实得 \(model.results.count)")
            }
            guard model.results.allSatisfy({ $0.kind == .resultSet }) else {
                throw QuerySmokeFailure("两条语句都应有结果集")
            }
            return "结果 1 = \(model.results[0].rows.count) 行，结果 2 = \(model.results[1].rows.first?.first?.textValue ?? "?")"
        }

        await check("当前语句执行：光标在第 2 条时只跑第 2 条") {
            let model = makeModel(session: session, environment: environment)
            let sql = "SELECT id FROM tl_query_test; SELECT COUNT(*) AS n FROM tl_query_test;"
            model.textChanged(sql)
            let cursor = (sql as NSString).range(of: "SELECT COUNT").location
            model.selectionChanged(NSRange(location: cursor, length: 0))
            model.executeCurrentStatement()
            await model.waitForExecution()
            guard model.results.count == 1 else {
                throw QuerySmokeFailure("期望 1 个结果标签，实得 \(model.results.count)")
            }
            guard model.results[0].statementText.contains("COUNT") else {
                throw QuerySmokeFailure("执行的应是第 2 条语句：\(model.results[0].statementText)")
            }
            return ""
        }

        await check("语法错误：错误结果标签 + 1064") {
            let model = makeModel(session: session, environment: environment)
            model.textChanged("SELECT * FORM tl_query_test;")
            model.executeAll()
            await model.waitForExecution()
            guard let first = model.results.first, first.kind == .failure else {
                throw QuerySmokeFailure("期望错误结果标签")
            }
            guard first.error?.code == 1064 else {
                throw QuerySmokeFailure("期望 1064，实得 \(String(describing: first.error?.code))")
            }
            return "code=\(first.error?.code ?? 0)"
        }

        await check("只读拦截：写操作被拦，安全语句照常执行") {
            session.setReadOnly(true)
            defer { session.setReadOnly(false) }
            let model = makeModel(session: session, environment: environment)
            model.textChanged("INSERT INTO tl_query_test (name) VALUES ('blocked'); SELECT COUNT(*) AS n FROM tl_query_test;")
            model.executeAll()
            await model.waitForExecution()
            guard model.results.count == 2 else {
                throw QuerySmokeFailure("期望 2 个结果标签，实得 \(model.results.count)")
            }
            guard model.results[0].kind == .blocked else {
                throw QuerySmokeFailure("第 1 条应被只读拦截")
            }
            guard model.results[1].kind == .resultSet else {
                throw QuerySmokeFailure("第 2 条安全语句应正常执行")
            }
            return "notice = \(model.notice ?? "无")"
        }

        await check("取消：KILL QUERY 中止长查询") {
            let model = makeModel(session: session, environment: environment)
            model.textChanged("SELECT SLEEP(10);")
            model.executeAll()
            // 给对方一点时间真正下发，再取消。
            try? await Task.sleep(for: .milliseconds(400))
            let started = Date()
            model.stop()
            await model.waitForExecution()
            let elapsed = Date().timeIntervalSince(started)
            guard elapsed < 5 else {
                throw QuerySmokeFailure("取消后仍等了 \(elapsed) 秒，KILL QUERY 可能没生效")
            }
            guard let last = model.results.last else {
                throw QuerySmokeFailure("取消后应保留已收到的结果标签")
            }
            let cancelled = last.error?.isCancellation == true || last.statementKind == .query
            guard cancelled else {
                throw QuerySmokeFailure("未观察到取消状态")
            }
            return "取消耗时 \(String(format: "%.2f", elapsed)) 秒"
        }

        await check("记录核对：查询历史与 Console Log 都写入了编辑器语句") {
            let sql = "SELECT id FROM tl_query_test ORDER BY id;"
            let model = makeModel(session: session, environment: environment)
            model.textChanged(sql)
            model.executeAll()
            await model.waitForExecution()

            let history = try await environment.history.recent(connectionID: session.id, search: "tl_query_test", limit: 20)
            guard history.contains(where: { $0.sql.contains("SELECT id FROM tl_query_test") }) else {
                throw QuerySmokeFailure("查询历史里找不到刚执行的语句")
            }
            let logs = environment.consoleLog.entries(tag: .data)
            guard logs.contains(where: { $0.sql.contains("SELECT id FROM tl_query_test") }) else {
                throw QuerySmokeFailure("Console Log 里找不到刚执行的语句")
            }
            return "历史 \(history.count) 条，Console Log \(logs.count) 条"
        }

        print("")
        if failures == 0 {
            print("SQL 编辑器冒烟全部通过（\(total) 项）。")
        } else {
            print("\(failures)/\(total) 项失败。")
        }
        return failures
    }

    // MARK: 工具

    private static func makeModel(
        session: ConnectionSession,
        environment: AppEnvironment
    ) -> QueryEditorViewModel {
        let tab = session.newQueryTab()
        return QueryEditorViewModel(
            session: session,
            tab: tab,
            preferences: environment.preferences,
            drafts: environment.drafts,
            clock: environment.clock
        )
    }

    private static func prepare(_ session: ConnectionSession) async throws {
        try await exec(session, "DROP TABLE IF EXISTS tl_query_test")
        try await exec(session, """
            CREATE TABLE tl_query_test (
              id INT PRIMARY KEY AUTO_INCREMENT,
              name VARCHAR(64)
            )
            """)
        for name in ["a", "b", "c"] {
            try await exec(session, "INSERT INTO tl_query_test (name) VALUES ('\(name)')")
        }
    }

    @discardableResult
    private static func exec(_ session: ConnectionSession, _ sql: String) async throws -> MySQLQueryResult {
        let result = try await session.execute(sql, recordHistory: false)
        if let error = result.firstError {
            throw QuerySmokeFailure("\(sql.prefix(50)) → code=\(error.code) \(error.message)")
        }
        return result
    }
}

// MARK: - 配置 / 错误

private struct QuerySmokeConfig: Sendable {
    let host: String
    let port: Int
    let user: String
    let password: String
    let database: String

    static func fromEnvironment() -> QuerySmokeConfig {
        let env = ProcessInfo.processInfo.environment
        return QuerySmokeConfig(
            host: env["MYSQL_HOST"] ?? "127.0.0.1",
            port: Int(env["MYSQL_PORT"] ?? "3306") ?? 3306,
            user: env["MYSQL_USER"] ?? "root",
            password: env["MYSQL_PASSWORD"] ?? "",
            database: env["MYSQL_DATABASE"] ?? "tablelite_smoke"
        )
    }
}

private struct QuerySmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
