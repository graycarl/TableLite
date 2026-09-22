import Foundation
import Darwin

/// 编辑链路的端到端冒烟验证（隐藏参数 `--edit-smoke`）。
///
/// 覆盖：可编辑性判定 → 字段栏进暂存 → 预览与实际提交逐字节一致（S29）→
/// 事务提交落库 → 唯一键冲突回滚且保留暂存 → 复制行（自增主键清空）。
///
/// 用法（环境变量与 `scripts/smoke/run.sh` 一致）：
///
///     MYSQL_HOST=127.0.0.1 MYSQL_PORT=13306 MYSQL_USER=root MYSQL_PASSWORD=tablelite \
///       TableLite.app/Contents/MacOS/TableLite --edit-smoke
///
/// 与 `--smoke`（访问层）分开：本模式必须驱动 `@MainActor` 的 `TableDataViewModel`，
/// 因此不能在主线程上阻塞等待；由 `TableLiteApp.init` 调度后在主运行循环里执行并 `exit`。
@MainActor
enum EditSmokeRunner {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--edit-smoke")
    }

    static func scheduleIfRequested() {
        guard isRequested else { return }
        Task { @MainActor in
            let code = await runAll()
            fflush(stdout)
            exit(code == 0 ? 0 : 1)
        }
    }

    // MARK: 编排

    private static func runAll() async -> Int {
        let config = EditSmokeConfig.fromEnvironment()
        print("== TableLite 编辑冒烟（字段栏 → 暂存 → 预览 → 提交）==")
        print("   目标：\(config.user)@\(config.host):\(config.port)/\(config.database)\n")

        let environment = AppEnvironment.makeFallback()
        let connection = Connection(
            id: UUID(),
            name: "edit-smoke",
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
        // 目标库可能还不存在（首次跑）：连上后创建并选中。
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
        let expected = 5

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

        await check("有主键的表可编辑并打开数据") {
            let viewModel = makeViewModel(environment: environment, session: session, table: "tl_edit_pk")
            await viewModel.start()
            guard viewModel.isEditable else { throw EditSmokeFailure("有主键的表应判定为可编辑") }
            guard viewModel.rows.count == 2 else { throw EditSmokeFailure("期望 2 行，实得 \(viewModel.rows.count)") }
            return "\(viewModel.rows.count) 行 · \(viewModel.columns.count) 列"
        }

        await check("无主键的表只读并给出原因") {
            let viewModel = makeViewModel(environment: environment, session: session, table: "tl_edit_nopk")
            await viewModel.start()
            guard !viewModel.isEditable else { throw EditSmokeFailure("无主键的表不应可编辑") }
            guard viewModel.editability.reason == .noPrimaryKey else {
                throw EditSmokeFailure("原因应为 noPrimaryKey，实得 \(String(describing: viewModel.editability.reason))")
            }
            return viewModel.uneditableStatusText ?? ""
        }

        await check("编辑 + 新增 → 暂存 → 预览 == 实际提交 → 数据落库") {
            let viewModel = makeViewModel(environment: environment, session: session, table: "tl_edit_pk")
            await viewModel.start()
            guard let first = viewModel.rows.first else { throw EditSmokeFailure("没有可编辑的行") }

            await viewModel.applyInspectorEdit(rowID: first.id, column: "name", value: .text("张三改"))
            viewModel.beginInsert()
            guard let insertion = viewModel.insertionRows.first else { throw EditSmokeFailure("插入行未出现") }
            await viewModel.applyInspectorEdit(rowID: insertion.id, column: "name", value: .text("新增"))
            await viewModel.applyInspectorEdit(rowID: insertion.id, column: "email", value: .text("new@z.z"))

            guard viewModel.pendingCount == 2 else {
                throw EditSmokeFailure("期望暂存 2 条，实得 \(viewModel.pendingCount)")
            }
            viewModel.presentPreview()
            let preview = viewModel.previewStatements
            guard preview.count == 2 else { throw EditSmokeFailure("预览应有 2 条，实得 \(preview.count)") }

            let logCountBefore = environment.consoleLog.allEntries.count
            let succeeded = await viewModel.submitChanges()
            guard succeeded else {
                throw EditSmokeFailure("提交失败：\(viewModel.commitFailure?.message ?? "未知错误")")
            }
            // 预览与实际下发逐字节一致（S29）。
            let actual = environment.consoleLog.allEntries
                .dropFirst(logCountBefore)
                .map(\.sql)
                .filter { $0.hasPrefix("INSERT") || $0.hasPrefix("UPDATE") || $0.hasPrefix("DELETE") }
            guard actual == preview else {
                throw EditSmokeFailure("预览与实际提交不一致：\n预览 \(preview)\n实际 \(actual)")
            }
            guard viewModel.pendingStore.isEmpty else { throw EditSmokeFailure("提交成功后暂存应清空") }

            // 落库校验。
            let totalRows = try await scalar(session, "SELECT COUNT(*) FROM tl_edit_pk")
            guard totalRows == "3" else { throw EditSmokeFailure("提交后应有 3 行，实得 \(totalRows)") }
            let changed = try await scalar(session, "SELECT `name` FROM tl_edit_pk WHERE `email` = 'a@b.c'")
            guard changed == "张三改" else { throw EditSmokeFailure("修改未落库：name=\(changed)") }
            return "2 条语句提交成功，预览与下发一致"
        }

        await check("唯一键冲突 → ROLLBACK、暂存保留、数据未变") {
            let viewModel = makeViewModel(environment: environment, session: session, table: "tl_edit_pk")
            await viewModel.start()
            guard let second = viewModel.rows.first(where: { $0.cells["email"]?.displayValue == .text("d@e.f") }) else {
                throw EditSmokeFailure("找不到第二行")
            }
            await viewModel.applyInspectorEdit(rowID: second.id, column: "email", value: .text("a@b.c"))
            let before = await viewModel.pendingCount
            let succeeded = await viewModel.submitChanges()
            guard !succeeded else { throw EditSmokeFailure("重复的 email 应导致提交失败") }
            guard viewModel.pendingCount == before else { throw EditSmokeFailure("失败后暂存应保留") }
            let email = try await scalar(session, "SELECT `email` FROM tl_edit_pk WHERE `name` = '李四'")
            guard email == "d@e.f" else { throw EditSmokeFailure("回滚后数据被改动：email=\(email)") }
            return "错误码 \(viewModel.commitFailure?.code ?? 0)，暂存保留 \(viewModel.pendingCount) 条"
        }

        await check("复制行：自增主键清空、值随原行") {
            let viewModel = makeViewModel(environment: environment, session: session, table: "tl_edit_pk")
            await viewModel.start()
            guard let first = viewModel.rows.first else { throw EditSmokeFailure("没有可复制的行") }
            await viewModel.copySelectedRows(rowIDs: [first.id])
            guard viewModel.insertionRows.count == 1 else {
                throw EditSmokeFailure("复制后应有 1 个新增行，实得 \(viewModel.insertionRows.count)")
            }
            // 复制的 email 是唯一键，换一个新值再由数据库生成自增主键。
            guard let insertion = viewModel.insertionRows.first else { throw EditSmokeFailure("新增行缺失") }
            await viewModel.applyInspectorEdit(rowID: insertion.id, column: "email", value: .text("copy@z.z"))
            let statements = try viewModel.makeStatements()
            guard statements.count == 1, statements[0].hasPrefix("INSERT INTO") else {
                throw EditSmokeFailure("应生成 1 条 INSERT")
            }
            guard !statements[0].contains("`id`") else { throw EditSmokeFailure("自增主键列应留空") }
            let succeeded = await viewModel.submitChanges()
            guard succeeded else { throw EditSmokeFailure("复制行提交失败") }
            let totalRows = try await scalar(session, "SELECT COUNT(*) FROM tl_edit_pk")
            guard totalRows == "4" else { throw EditSmokeFailure("复制后应有 4 行，实得 \(totalRows)") }
            return "INSERT 不含 id，提交后 4 行"
        }

        print("")
        if failures == 0 {
            print("编辑冒烟全部通过（\(total) 项）。")
        } else {
            print("\(failures)/\(total) 项失败。")
        }
        return failures
    }

    // MARK: 准备与工具

    private static func prepare(_ session: ConnectionSession) async throws {
        try await exec(session, "DROP TABLE IF EXISTS tl_edit_pk")
        try await exec(session, "DROP TABLE IF EXISTS tl_edit_nopk")
        try await exec(session, """
            CREATE TABLE tl_edit_pk (
              id INT PRIMARY KEY AUTO_INCREMENT,
              name VARCHAR(64),
              email VARCHAR(64) UNIQUE,
              content TEXT
            )
            """)
        try await exec(session, "INSERT INTO tl_edit_pk (name, email, content) VALUES ('张三', 'a@b.c', 'hello')")
        try await exec(session, "INSERT INTO tl_edit_pk (name, email, content) VALUES ('李四', 'd@e.f', 'world')")
        try await exec(session, "CREATE TABLE tl_edit_nopk (name VARCHAR(64), email VARCHAR(64))")
        try await exec(session, "INSERT INTO tl_edit_nopk VALUES ('王五', 'g@h.i')")
    }

    private static func makeViewModel(
        environment: AppEnvironment,
        session: ConnectionSession,
        table: String
    ) -> TableDataViewModel {
        let database = session.selectedDatabase ?? session.connection.mysql.database
        let tab = session.openTableData(database: database, table: table, forceNew: true)
        return TableDataViewModel(
            session: session,
            tab: tab,
            preferences: environment.preferences,
            clock: environment.clock
        )
    }

    @discardableResult
    private static func exec(_ session: ConnectionSession, _ sql: String) async throws -> MySQLQueryResult {
        let result = try await session.execute(sql, recordHistory: false)
        if let error = result.firstError {
            throw EditSmokeFailure("\(sql.prefix(60)) → code=\(error.code) \(error.message)")
        }
        return result
    }

    private static func scalar(_ session: ConnectionSession, _ sql: String) async throws -> String {
        let result = try await exec(session, sql)
        guard let text = result.firstResultSet?.rows.first?.cells.first?.text else { return "" }
        return text
    }
}

// MARK: - 配置 / 错误

private struct EditSmokeConfig: Sendable {
    let host: String
    let port: Int
    let user: String
    let password: String
    let database: String

    static func fromEnvironment() -> EditSmokeConfig {
        let env = ProcessInfo.processInfo.environment
        return EditSmokeConfig(
            host: env["MYSQL_HOST"] ?? "127.0.0.1",
            port: Int(env["MYSQL_PORT"] ?? "3306") ?? 3306,
            user: env["MYSQL_USER"] ?? "root",
            password: env["MYSQL_PASSWORD"] ?? "",
            database: env["MYSQL_DATABASE"] ?? "tablelite_smoke"
        )
    }
}

private struct EditSmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
