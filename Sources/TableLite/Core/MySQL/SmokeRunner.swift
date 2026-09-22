import Foundation
import Darwin
import Dispatch
import Synchronization

/// 访问层端到端冒烟验证：全部经由 `MySQLSession` 驱动，同时盖住 Swift 封装层与 C shim。
///
/// 7 项验证的语义与 `docs/tech-designs/03-mysql-layer.md` §8 一致；用法（由 `scripts/smoke/run.sh` 调用）：
///
///     TableLite.app/Contents/MacOS/TableLite --smoke
///
/// 这里不再直接触碰 C shim：依赖方向与封装边界见 `01-architecture.md` §1、`03-mysql-layer.md` §3。
enum SmokeRunner {

    /// 非 `--smoke` 调用时立即返回，不影响正常的 GUI 启动路径。
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--smoke") else { return }
        let exitCode = Atomic<Int>(0)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let code = await runAll()
            exitCode.store(code, ordering: .relaxed)
            semaphore.signal()
        }
        semaphore.wait()
        fflush(stdout)
        exit(exitCode.load(ordering: .relaxed) == 0 ? 0 : 1)
    }

    // MARK: - 检查编排

    private static let bigTableRows = 100_000

    private static func runAll() async -> Int {
        let config = SmokeConfig.fromEnvironment()
        print("== TableLite 冒烟验证（MySQLSession + libmysqlclient）==")
        print("   目标：\(config.user)@\(config.host):\(config.port)/\(config.database)")
        print("   客户端库：\(MySQLSession.clientLibraryVersion)\n")

        var failures = 0
        var total = 0

        func step(_ title: String, _ body: () async throws -> String) async {
            total += 1
            print("[\(total)/7] \(title)")
            do {
                let detail = try await body()
                print(detail.isEmpty ? "      OK" : "      OK  \(detail)")
            } catch {
                failures += 1
                print("      失败：\(error)")
            }
        }

        let session = MySQLSession()

        await step("libmysqlclient 已加载") {
            let version = MySQLSession.clientLibraryVersion
            guard !version.isEmpty else { throw SmokeFailure("客户端库版本为空") }
            return "版本 \(version)"
        }

        // 先不带库连接：目标库可能还不存在（首次跑），顺带验证不带库的连接路径。
        await step("能连上 MySQL") {
            try await session.connect(config.parameters(database: ""))
            return "thread_id \(await session.serverThreadID)"
        }

        // 准备数据；失败只提示，后续检查会各自报错。
        do {
            try await exec(session, "CREATE DATABASE IF NOT EXISTS `\(config.database)`")
            try await exec(session, "USE `\(config.database)`")
            try await prepareBigTable(session, rows: bigTableRows)
        } catch {
            print("      准备数据失败：\(error)")
        }

        await step("SELECT 1 返回一行一列") {
            let result = try await exec(session, "SELECT 1")
            guard result.resultSets.count == 1 else {
                throw SmokeFailure("期望 1 个结果集，实得 \(result.resultSets.count)")
            }
            let set = result.resultSets[0]
            guard set.header.columns.count == 1, set.rows.count == 1 else {
                throw SmokeFailure("期望 1 列 1 行，实得 \(set.header.columns.count) 列 \(set.rows.count) 行")
            }
            let cell = set.rows[0].cells[0]
            guard cell.text == "1" else { throw SmokeFailure("期望值 1，实得 \(cell.text ?? "NULL")") }
            return "值 = 1"
        }

        await step("多语句与 CALL 都能取完全部结果集") {
            let multi = try await exec(session, "SELECT 1 AS a; SELECT 2 AS b;")
            let multiSets = multi.resultSets.filter { $0.header.hasColumns }
            guard multiSets.count == 2 else {
                throw SmokeFailure("多语句期望 2 个结果集，实得 \(multiSets.count)")
            }
            let values = multiSets.compactMap { $0.rows.first?.cells.first?.text }
            guard values == ["1", "2"] else { throw SmokeFailure("多语句期望 [1, 2]，实得 \(values)") }

            try await exec(session, "DROP PROCEDURE IF EXISTS tl_smoke_proc")
            try await exec(session, """
                CREATE PROCEDURE tl_smoke_proc()
                BEGIN
                  SELECT 11 AS a;
                  SELECT 22 AS b;
                END
                """)
            let call = try await exec(session, "CALL tl_smoke_proc()")
            let callSets = call.resultSets.filter { $0.header.hasColumns }
            guard callSets.count == 2 else {
                throw SmokeFailure("CALL 期望 2 个结果集，实得 \(callSets.count)（全部结果集 \(call.resultSets.count) 个）")
            }
            let callValues = callSets.compactMap { $0.rows.first?.cells.first?.text }
            guard callValues == ["11", "22"] else { throw SmokeFailure("CALL 期望 [11, 22]，实得 \(callValues)") }
            return "多语句 2 个结果集；CALL \(call.resultSets.count) 个（2 个带列）"
        }

        await step("单引号 / 反斜杠 / 换行 / emoji / NUL / 二进制往返一致") {
            let cases: [(binary: [UInt8], text: String)] = [
                ([0x00, 0x1B, 0x27, 0x5C, 0xFF, 0xFE], "quote ' backslash \\ end"),
                ([0x80], "line1\nline2\ttab 😀"),
                ([], "nul\u{0}inside"),
                ([0x00], ""),
            ]

            try await exec(session, "DROP TABLE IF EXISTS tl_smoke_rt")
            try await exec(session, "CREATE TABLE tl_smoke_rt (id INT PRIMARY KEY AUTO_INCREMENT, b VARBINARY(255), t TEXT)")

            for item in cases {
                let literal = item.binary.isEmpty
                    ? "X''"
                    : "0x" + item.binary.map { String(format: "%02X", $0) }.joined()
                // 走 MySQLSession 的连接转义器（S29：Preview 与下发共用转义路径）。
                let escaped = session.escape(item.text)
                try await exec(session, "INSERT INTO tl_smoke_rt (b, t) VALUES (\(literal), '\(escaped)')")
            }

            let read = try await exec(session, "SELECT b, t FROM tl_smoke_rt ORDER BY id")
            guard let set = read.resultSets.first, set.rows.count == cases.count else {
                throw SmokeFailure("读回行数不符：\(read.resultSets.first?.rows.count ?? -1)")
            }

            for (index, item) in cases.enumerated() {
                let row = set.rows[index]
                guard row.cells[0] == .bytes(Data(item.binary)) else {
                    throw SmokeFailure("第 \(index + 1) 行二进制不一致：期望 \(hex(item.binary))，实得 \(hex(cellBytes(row.cells[0])))")
                }
                guard row.cells[1] == .bytes(Data(item.text.utf8)) else {
                    throw SmokeFailure("第 \(index + 1) 行文本不一致：期望 \(hex([UInt8](item.text.utf8)))，实得 \(hex(cellBytes(row.cells[1])))")
                }
            }
            return "\(set.rows.count) 行全部逐字节一致（含 0x00 与 0xFF）"
        }

        await step("KILL QUERY 能中断长查询") {
            let victim = MySQLSession()
            try await victim.connect(config.parameters(database: config.database))

            let started = Date()
            let queryTask = Task {
                try await victim.execute("SELECT COUNT(*) FROM tl_smoke_big a, tl_smoke_big b WHERE a.id > b.id")
            }

            // 800ms 后取消：session 内部经独立控制连接发 KILL QUERY，只杀语句、不杀连接。
            try await Task.sleep(for: .milliseconds(800))
            do {
                try await victim.cancel()
            } catch {
                throw SmokeFailure("KILL QUERY 本身失败：\(error)")
            }

            let result: MySQLQueryResult
            do {
                result = try await queryTask.value
            } catch {
                throw SmokeFailure("查询未返回错误结果：\(error)")
            }
            let elapsed = Date().timeIntervalSince(started)

            guard elapsed < 10 else {
                throw SmokeFailure("查询未被中断，耗时 \(fmt(elapsed))s")
            }
            guard let error = result.firstError else {
                throw SmokeFailure("查询未被中断，却正常返回了（耗时 \(fmt(elapsed))s）")
            }
            // 1317 = ER_QUERY_INTERRUPTED（KILL QUERY 的标准结果）
            guard error.code == 1317 else {
                throw SmokeFailure("期望错误码 1317，实得 \(error.code) \(error.message)")
            }
            // KILL QUERY 只杀语句，连接必须还能用，而且不需要重建（缓冲模式不置 needs_reset）。
            guard await victim.isConnected else {
                throw SmokeFailure("KILL QUERY 后连接断开了")
            }
            guard await victim.autoReconnectCount == 0 else {
                throw SmokeFailure("KILL QUERY 不应要求重建连接（autoReconnectCount=\(await victim.autoReconnectCount)）")
            }
            try await exec(victim, "SELECT 1")
            await victim.disconnect()
            return "\(fmt(elapsed))s 后中断，错误码 \(error.code)，连接仍可继续使用"
        }

        await step("unbuffered 消费 10 万行时内存平稳") {
            let rows = bigTableRows
            let streamCount = Atomic<Int>(0)
            let streamPeak = Atomic<UInt64>(0)
            let baseForStreaming = residentSizeBytes()

            // 先流式（回调里只计数、不保留行），再缓冲：RSS 单调增长，顺序反了 buf 会把两个数字混在一起。
            let summary = try await session.streamQuery("SELECT id, payload FROM tl_smoke_big", unbuffered: true) { event in
                guard case .row = event else { return }
                let count = streamCount.wrappingAdd(1, ordering: .relaxed).newValue
                if count % 10_000 == 0 {
                    let rss = residentSizeBytes()
                    let growth = rss > baseForStreaming ? rss - baseForStreaming : 0
                    let previous = streamPeak.load(ordering: .relaxed)
                    if growth > previous {
                        streamPeak.store(growth, ordering: .relaxed)
                    }
                }
            }
            let streamingPeak = streamPeak.load(ordering: .relaxed)

            let baseForBuffered = residentSizeBytes()
            let buffered = try await session.execute("SELECT id, payload FROM tl_smoke_big", unbuffered: false)
            let bufferedPeak = residentSizeBytes() > baseForBuffered ? residentSizeBytes() - baseForBuffered : 0

            guard summary.rowCount == rows else {
                throw SmokeFailure("流式期望 \(rows) 行，实得 \(summary.rowCount)")
            }

            let limit: UInt64 = 16 * 1024 * 1024
            guard streamingPeak < limit else {
                throw SmokeFailure("流式内存增长 \(mb(streamingPeak)) 超过阈值 \(mb(limit))")
            }
            let note = bufferedPeak > streamingPeak
                ? "（同样 \(buffered.rowCount) 行，缓冲模式 \(mb(bufferedPeak)) —— 流式确实省内存）"
                : "（⚠️ 缓冲模式只增长 \(mb(bufferedPeak))，本次测量区分度不足）"
            return "\(rows) 行流式增长 \(mb(streamingPeak))\(note)"
        }

        await session.disconnect()

        print("")
        if failures == 0 {
            print("全部通过（\(total) 项）。")
        } else {
            print("\(failures)/\(total) 项失败。")
        }
        return failures
    }

    // MARK: - 连接与执行

    /// 第 6、7 项都需要的宽表：第 6 项拿它做自连接当「长时间运行的查询」，第 7 项拿它测流式。
    private static func prepareBigTable(_ session: MySQLSession, rows: Int) async throws {
        let batch = 1_000
        try await exec(session, "DROP TABLE IF EXISTS tl_smoke_big")
        try await exec(session, "CREATE TABLE tl_smoke_big (id INT PRIMARY KEY AUTO_INCREMENT, payload VARCHAR(255))")
        for _ in 0..<(rows / batch) {
            let values = Array(repeating: "(REPEAT('x',255))", count: batch).joined(separator: ",")
            try await exec(session, "INSERT INTO tl_smoke_big (payload) VALUES \(values)")
        }
    }

    /// 执行并检查语句级错误。
    @discardableResult
    private static func exec(_ session: MySQLSession, _ sql: String) async throws -> MySQLQueryResult {
        let result: MySQLQueryResult
        do {
            result = try await session.execute(sql)
        } catch let error as MySQLError {
            throw SmokeFailure("\(sql.prefix(60)) → code=\(error.code) \(error.message)")
        }
        if let error = result.firstError {
            throw SmokeFailure("\(sql.prefix(60)) → code=\(error.code) \(error.message)")
        }
        return result
    }
}

// MARK: - 配置

private struct SmokeConfig: Sendable {
    let host: String
    let port: UInt32
    let user: String
    let password: String
    let database: String

    static func fromEnvironment() -> SmokeConfig {
        let env = ProcessInfo.processInfo.environment
        return SmokeConfig(
            host: env["MYSQL_HOST"] ?? "127.0.0.1",
            port: UInt32(env["MYSQL_PORT"] ?? "3306") ?? 3306,
            user: env["MYSQL_USER"] ?? "root",
            password: env["MYSQL_PASSWORD"] ?? "",
            database: env["MYSQL_DATABASE"] ?? "tablelite_smoke"
        )
    }

    func parameters(database: String) -> MySQLConnectionParameters {
        MySQLConnectionParameters(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database,
            charset: "utf8mb4",
            connectTimeout: 10,
            queryTimeout: 300
        )
    }
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: - 工具

private func cellBytes(_ cell: MySQLCell) -> [UInt8] {
    switch cell {
    case .null: return []
    case .bytes(let data): return [UInt8](data)
    }
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
}

private func fmt(_ seconds: TimeInterval) -> String {
    String(format: "%.2f", seconds)
}

private func mb(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
}

/// 当前进程的常驻内存大小（RSS）。
private func residentSizeBytes() -> UInt64 {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}
