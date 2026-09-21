import Foundation
import Darwin
import CMySQLClient

/// Phase 0 的端到端冒烟验证：证明「C shim + libmysqlclient + 真实 MySQL 服务器」这条链路是通的。
///
/// 验收标准见 `docs/tech-designs/03-mysql-layer.md` §8。
///
/// 用法（由 `scripts/smoke/run.sh` 调用）：
///
///     TableLite.app/Contents/MacOS/TableLite --smoke
///
/// ⚠️ 这里是 Phase 0 的临时产物：只直接使用 C shim，因为 `MySQLSession` 还不存在。
///    P1 落地 `MySQLSession` 之后，本文件应当改写为由 `MySQLSession` 驱动 —— 那时它才能同时
///    验证 Swift 封装层，而不只是 C 层。见 `docs/roadmap.md` 的 P0/P1。
///
/// 注：本文件位于 `Core/MySQL`，不属于 UI 层，因此直接 `import CMySQLClient` 不违反
///     `01-architecture.md` §1 的依赖方向约束。
enum SmokeRunner {

    /// 非 `--smoke` 调用时立即返回，不影响正常的 GUI 启动路径。
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--smoke") else { return }
        let failed = runAll()
        fflush(stdout)
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - 检查编排

    private static func runAll() -> Int {
        let config = SmokeConfig.fromEnvironment()
        print("== TableLite 冒烟验证（C shim + libmysqlclient）==")
        print("   目标：\(config.user)@\(config.host):\(config.port)/\(config.database)")
        print("   客户端库：\(cString(mtl_client_version()))\n")

        var failures = 0
        var total = 0

        func step(_ title: String, _ body: () throws -> String) {
            total += 1
            print("[\(total)/7] \(title)")
            do {
                let detail = try body()
                print(detail.isEmpty ? "      OK" : "      OK  \(detail)")
            } catch {
                failures += 1
                print("      失败：\(error)")
            }
        }

        step("libmysqlclient 已加载") {
            let version = cString(mtl_client_version())
            guard !version.isEmpty else { throw SmokeFailure("mtl_client_version() 返回空串") }
            return "版本 \(version)"
        }

        // 连接在后续检查之间复用；第 6 项另开一条控制连接。
        var main: OpaquePointer?
        defer { if let main { mtl_conn_free(main) } }

        // 先不带库连接：目标库可能还不存在（首次跑），而且这样能顺带验一下不带库的连接
        step("能连上 MySQL") {
            main = try connect(config, database: "")
            guard let main else { throw SmokeFailure("连接句柄为空") }
            return "服务器 \(cString(mtl_conn_server_version(main)))，thread_id \(mtl_conn_thread_id(main))"
        }

        guard let conn = main else {
            print("\n连接未建立，后续检查无法进行。")
            return failures
        }

        // 准备一个专用的库，避免污染别的数据
        do {
            try exec(conn, "CREATE DATABASE IF NOT EXISTS `\(config.database)`")
            try exec(conn, "USE `\(config.database)`")
            try prepareBigTable(conn, rows: Self.bigTableRows)
        } catch {
            print("      准备数据失败：\(error)")
        }

        step("SELECT 1 返回一行一列") {
            let c = QueryCollector()
            try exec(conn, "SELECT 1", collector: c)
            guard c.resultSets.count == 1 else {
                throw SmokeFailure("期望 1 个结果集，实得 \(c.resultSets.count)")
            }
            let rs = c.resultSets[0]
            guard rs.columnCount == 1, rs.rowCount == 1 else {
                throw SmokeFailure("期望 1 列 1 行，实得 \(rs.columnCount) 列 \(rs.rowCount) 行")
            }
            let cell = c.keptRows[0][0][0]
            guard cell.text == "1" else { throw SmokeFailure("期望值 1，实得 \(cell.text)") }
            return "值 = 1"
        }

        step("多语句与 CALL 都能取完全部结果集") {
            // 一次下发多条语句
            let multi = QueryCollector()
            try exec(conn, "SELECT 1 AS a; SELECT 2 AS b;", collector: multi)
            let multiSets = multi.resultSets.filter { $0.columnCount > 0 }
            guard multiSets.count == 2 else {
                throw SmokeFailure("多语句期望 2 个结果集，实得 \(multiSets.count)")
            }
            let values = multi.keptRows.compactMap { $0.first?.first?.text }
            guard values == ["1", "2"] else { throw SmokeFailure("多语句期望 [1, 2]，实得 \(values)") }

            // 单条 CALL 本身可能返回多个结果集
            try exec(conn, "DROP PROCEDURE IF EXISTS tl_smoke_proc")
            try exec(conn, """
                CREATE PROCEDURE tl_smoke_proc()
                BEGIN
                  SELECT 11 AS a;
                  SELECT 22 AS b;
                END
                """)
            let call = QueryCollector()
            try exec(conn, "CALL tl_smoke_proc()", collector: call)
            let callSets = call.resultSets.filter { $0.columnCount > 0 }
            guard callSets.count == 2 else {
                throw SmokeFailure("CALL 期望 2 个结果集，实得 \(callSets.count)（全部结果集 \(call.resultSets.count) 个）")
            }
            let callValues = call.keptRows.compactMap { $0.first?.first?.text }
            guard callValues == ["11", "22"] else {
                throw SmokeFailure("CALL 期望 [11, 22]，实得 \(callValues)")
            }
            return "多语句 2 个结果集；CALL \(call.resultSets.count) 个（2 个带列）"
        }

        step("单引号 / 反斜杠 / 换行 / emoji / NUL / 二进制往返一致") {
            let cases: [(binary: [UInt8], text: String)] = [
                ([0x00, 0x1B, 0x27, 0x5C, 0xFF, 0xFE], "quote ' backslash \\ end"),
                ([0x80], "line1\nline2\ttab 😀"),
                ([], "nul\u{0}inside"),
                ([0x00], ""),
            ]

            try exec(conn, "DROP TABLE IF EXISTS tl_smoke_rt")
            try exec(conn, "CREATE TABLE tl_smoke_rt (id INT PRIMARY KEY AUTO_INCREMENT, b VARBINARY(255), t TEXT)")

            for item in cases {
                let literal = item.binary.isEmpty
                    ? "X''"
                    : "0x" + item.binary.map { String(format: "%02X", $0) }.joined()
                try exec(conn, "INSERT INTO tl_smoke_rt (b, t) VALUES (\(literal), '\(try escape(conn, item.text))')")
            }

            let read = QueryCollector()
            try exec(conn, "SELECT b, t FROM tl_smoke_rt ORDER BY id", collector: read)
            guard read.resultSets.first?.rowCount == cases.count else {
                throw SmokeFailure("读回行数不符：\(read.resultSets.first?.rowCount ?? -1)")
            }

            let rows = read.keptRows[0]
            for (i, item) in cases.enumerated() {
                guard rows[i][0].bytes == item.binary else {
                    throw SmokeFailure("第 \(i + 1) 行二进制不一致：期望 \(hex(item.binary))，实得 \(hex(rows[i][0].bytes))")
                }
                guard rows[i][1].bytes == [UInt8](item.text.utf8) else {
                    throw SmokeFailure("第 \(i + 1) 行文本不一致：期望 \(hex([UInt8](item.text.utf8)))，实得 \(hex(rows[i][1].bytes))")
                }
            }
            return "\(rows.count) 行全部逐字节一致（含 0x00 与 0xFF）"
        }

        step("KILL QUERY 能中断长查询") {
            // 这条连接显式带上库名，顺便盖上 database 参数
            let control = try connect(config, database: config.database)
            defer { mtl_conn_free(control) }

            let victimThreadId = UInt64(mtl_conn_thread_id(conn))
            let sender = KillSender(handle: control, threadId: victimThreadId)
            let done = DispatchSemaphore(value: 0)

            // 800ms 后从控制连接发 KILL QUERY；只杀语句，不杀连接
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
                sender.send()
                done.signal()
            }

            // 受害者必须是一个**真正跑得久、且不会吞掉中断**的查询。三个坑都踩过了：
            //   · `SELECT SLEEP(n)` 被 KILL 后直接返回 1、语句成功结束；
            //   · `BENCHMARK()` 同理，而且可能自己就跑完了；
            //   · `SELECT COUNT(*) FROM t, t` 不带条件时，MySQL 8.4 用行数直接相乘返回。
            // `WHERE a.id > b.id` 强制嵌套循环，没法被优化成常数乘法，也跑不出哈希连接。
            let started = Date()
            var queryError: SmokeFailure?
            do {
                try exec(conn, "SELECT COUNT(*) FROM tl_smoke_big a, tl_smoke_big b WHERE a.id > b.id")
            } catch let failure as SmokeFailure {
                queryError = failure
            }
            let elapsed = Date().timeIntervalSince(started)

            _ = done.wait(timeout: .now() + 10)

            if !sender.ok {
                throw SmokeFailure("KILL QUERY 本身失败：rc=\(sender.rc) code=\(sender.code) \(sender.message)")
            }
            guard let failure = queryError else {
                throw SmokeFailure("查询未被中断，却正常返回了（耗时 \(fmt(elapsed))s）")
            }
            guard elapsed < 10 else {
                throw SmokeFailure("查询未被中断，耗时 \(fmt(elapsed))s")
            }
            // 1317 = ER_QUERY_INTERRUPTED（KILL QUERY 的标准结果）
            guard failure.code == 1317 else {
                throw SmokeFailure("期望错误码 1317，实得 \(failure.code)（rc=\(failure.rc)）：\(failure.message)")
            }

            // KILL QUERY 只杀语句，连接必须还能用
            guard mtl_conn_is_open(conn) == 1 else {
                throw SmokeFailure("KILL QUERY 后连接断开了")
            }
            if mtl_conn_needs_reset(conn) != 0 {
                throw SmokeFailure("KILL QUERY 不应要求重建连接（needs_reset != 0）")
            }
            try exec(conn, "SELECT 1")
            return "\(fmt(elapsed))s 后中断，错误码 \(failure.code)，连接仍可继续使用"
        }

        step("unbuffered 消费 10 万行时内存平稳") {
            let rows = Self.bigTableRows

            // 先流式，再缓冲：RSS 单调增长，顺序反了 buf 会把两个数字混在一起
            let streamed = QueryCollector(sampleEvery: 10_000)
            let baseForStreaming = residentSizeBytes()
            try exec(conn, "SELECT id, payload FROM tl_smoke_big", collector: streamed, unbuffered: true)
            let streamingPeak = streamed.peakRSS - baseForStreaming

            let buffered = QueryCollector(sampleEvery: 10_000)
            let baseForBuffered = residentSizeBytes()
            try exec(conn, "SELECT id, payload FROM tl_smoke_big", collector: buffered)
            let bufferedPeak = buffered.peakRSS - baseForBuffered

            guard streamed.resultSets.first?.rowCount == rows else {
                throw SmokeFailure("流式期望 \(rows) 行，实得 \(streamed.resultSets.first?.rowCount ?? -1)")
            }

            let limit: UInt64 = 16 * 1024 * 1024
            guard streamingPeak < limit else {
                throw SmokeFailure("流式内存增长 \(mb(streamingPeak)) 超过阈值 \(mb(limit))")
            }
            let note = bufferedPeak > streamingPeak
                ? "（同样 10 万行，缓冲模式 \(mb(bufferedPeak)) —— 流式确实省内存）"
                : "（⚠️ 缓冲模式只增长 \(mb(bufferedPeak))，本次测量区分度不足）"
            return "\(rows) 行流式增长 \(mb(streamingPeak))\(note)"
        }

        print("")
        if failures == 0 {
            print("全部通过（\(total) 项）。")
        } else {
            print("\(failures)/\(total) 项失败。")
        }
        return failures
    }

    // MARK: - 连接与执行

    /// 第 6、7 项都需要的宽表：第 6 项拿它做自连接当“长时间运行的查询”，第 7 项拿它测流式。
    private static let bigTableRows = 100_000

    private static func prepareBigTable(_ handle: OpaquePointer, rows: Int) throws {
        let batch = 1_000
        try exec(handle, "DROP TABLE IF EXISTS tl_smoke_big")
        try exec(handle, "CREATE TABLE tl_smoke_big (id INT PRIMARY KEY AUTO_INCREMENT, payload VARCHAR(255))")
        for _ in 0..<(rows / batch) {
            let values = Array(repeating: "(REPEAT('x',255))", count: batch).joined(separator: ",")
            try exec(handle, "INSERT INTO tl_smoke_big (payload) VALUES \(values)")
        }
    }

    /// `database` 传空串表示不指定库（C 侧把空串当作 NULL）。
    private static func connect(_ config: SmokeConfig, database: String) throws -> OpaquePointer {
        guard let handle = mtl_conn_create() else {
            throw SmokeFailure("mtl_conn_create() 返回 NULL")
        }
        mtl_conn_set_connect_timeout(handle, 10)

        var err = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        let rc = mtl_conn_open(handle,
                               config.host,
                               config.port,
                               config.user,
                               config.password,
                               database,
                               "utf8mb4",
                               nil,
                               &err,
                               err.count)
        guard rc == MTL_OK else {
            let message = cStringBuf(err)
            mtl_conn_free(handle)
            throw SmokeFailure("mtl_conn_open 失败（rc=\(rc)）：\(message)")
        }
        return handle
    }

    private static func escape(_ handle: OpaquePointer, _ value: String) throws -> String {
        let input = Array(value.utf8).map { CChar(bitPattern: $0) }
        var output = [CChar](repeating: 0, count: input.count * 2 + 16)
        let written = input.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                mtl_conn_escape(handle, inBuf.baseAddress, input.count, outBuf.baseAddress, outBuf.count)
            }
        }
        guard written < output.count else {
            throw SmokeFailure("mtl_conn_escape 返回的长度 \(written) 超出缓冲区")
        }
        return String(decoding: output.prefix(written).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @discardableResult
    private static func exec(_ handle: OpaquePointer,
                            _ sql: String,
                            collector: QueryCollector? = nil,
                            unbuffered: Bool = false) throws -> Int32 {
        let result = execRaw(handle, sql, collector: collector, unbuffered: unbuffered)
        guard result.rc == MTL_OK else {
            throw SmokeFailure("\(sql.prefix(60)) → rc=\(result.rc) code=\(result.code) \(result.message)",
                               rc: result.rc, code: result.code, message: result.message)
        }
        return result.rc
    }

    private static func execRaw(_ handle: OpaquePointer,
                                _ sql: String,
                                collector: QueryCollector? = nil,
                                unbuffered: Bool = false) -> (rc: Int32, code: UInt32, message: String) {
        var err = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        var rc: Int32 = 0

        if let collector {
            var callbacks = MTLCallbacks(
                ctx: Unmanaged.passUnretained(collector).toOpaque(),
                on_result_set: smokeOnResultSet,
                on_row: smokeOnRow,
                on_statement_error: smokeOnStatementError
            )
            rc = mtl_conn_query(handle, sql, sql.utf8.count, unbuffered ? 1 : 0, &callbacks, &err, err.count)
        } else {
            rc = mtl_conn_query(handle, sql, sql.utf8.count, unbuffered ? 1 : 0, nil, &err, err.count)
        }

        var message = cStringBuf(err)
        if message.isEmpty { message = cString(mtl_conn_error(handle)) }
        return (rc, mtl_conn_errno(handle), message)
    }
}

// MARK: - 配置

private struct SmokeConfig {
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
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    let rc: Int32
    let code: UInt32
    let message: String

    init(_ description: String, rc: Int32 = 0, code: UInt32 = 0, message: String = "") {
        self.description = description
        self.rc = rc
        self.code = code
        self.message = message
    }
}

// MARK: - 结果收集

/// 一个单元格的原始字节。`NULL` 与空串必须区分。
private enum Cell {
    case null
    case bytes([UInt8])

    var bytes: [UInt8] {
        switch self {
        case .null: return []
        case .bytes(let b): return b
        }
    }

    var text: String {
        switch self {
        case .null: return "NULL"
        case .bytes(let b): return String(decoding: b, as: UTF8.self)
        }
    }
}

/// 在 C 回调里累计结果集 / 行 / 语句错误，并按需采样进程 RSS。
///
/// 只在一次同步调用内使用，因此不需要任何同步原语。
private final class QueryCollector {
    struct Column {
        let name: String
        let type: UInt32
        let flags: UInt32
        let charsetNr: UInt32
    }

    struct ResultSet {
        let index: Int32
        let columnCount: Int32
        let affectedRows: Int64
        let columns: [Column]
        var rowCount: Int = 0
    }

    struct StatementError {
        let index: Int32
        let code: UInt32
        let sqlstate: String
        let message: String
    }

    private(set) var resultSets: [ResultSet] = []
    private(set) var statementErrors: [StatementError] = []
    private(set) var keptRows: [[[Cell]]] = []
    private(set) var peakRSS: UInt64 = 0

    private let sampleEvery: Int

    init(sampleEvery: Int = 0) {
        self.sampleEvery = sampleEvery
        self.peakRSS = residentSizeBytes()
    }

    func beginResultSet(_ rs: MTLResultSet) {
        var columns: [Column] = []
        if let pointer = rs.columns, rs.column_count > 0 {
            for i in 0..<Int(rs.column_count) {
                let column = pointer[i]
                columns.append(Column(name: cString(column.name),
                                      type: column.type,
                                      flags: column.flags,
                                      charsetNr: column.charset_nr))
            }
        }
        resultSets.append(ResultSet(index: rs.result_index,
                                    columnCount: rs.column_count,
                                    affectedRows: rs.affected_rows,
                                    columns: columns))
        keptRows.append([])
    }

    func appendRow(_ row: MTLRow) {
        guard !resultSets.isEmpty else { return }
        let last = resultSets.count - 1
        resultSets[last].rowCount += 1

        // 让调用方能直接按行号取值；超出上限的行只计数，不复制 —— 否则第 7 项就测不出流式
        if resultSets[last].rowCount <= 4 {
            var cells: [Cell] = []
            if let values = row.values {
                for i in 0..<Int(row.column_count) {
                    if let value = values[i] {
                        let length = row.lengths.map { Int($0[i]) } ?? 0
                        cells.append(.bytes([UInt8](UnsafeRawBufferPointer(start: value, count: length))))
                    } else {
                        cells.append(.null)
                    }
                }
            }
            keptRows[last].append(cells)
        }

        if sampleEvery > 0 && resultSets[last].rowCount % sampleEvery == 0 {
            peakRSS = max(peakRSS, residentSizeBytes())
        }
    }

    func appendStatementError(_ error: StatementError) {
        statementErrors.append(error)
    }
}

// MARK: - C 回调

private func smokeOnResultSet(ctx: UnsafeMutableRawPointer?, rs: UnsafePointer<MTLResultSet>?) {
    guard let ctx, let rs else { return }
    Unmanaged<QueryCollector>.fromOpaque(ctx).takeUnretainedValue().beginResultSet(rs.pointee)
}

private func smokeOnRow(ctx: UnsafeMutableRawPointer?, row: UnsafePointer<MTLRow>?) -> Int32 {
    guard let ctx, let row else { return 0 }
    Unmanaged<QueryCollector>.fromOpaque(ctx).takeUnretainedValue().appendRow(row.pointee)
    return 0
}

private func smokeOnStatementError(ctx: UnsafeMutableRawPointer?,
                                   resultIndex: Int32,
                                   code: UInt32,
                                   sqlstate: UnsafePointer<CChar>?,
                                   message: UnsafePointer<CChar>?) {
    guard let ctx else { return }
    Unmanaged<QueryCollector>.fromOpaque(ctx).takeUnretainedValue().appendStatementError(
        .init(index: resultIndex, code: code, sqlstate: cString(sqlstate), message: cString(message))
    )
}

// MARK: - KILL QUERY 的控制连接

/// 在后台线程上向控制连接下发 `KILL QUERY`。
///
/// `@unchecked Sendable` 的理由（AGENTS.md 的唯一例外条款：包装 C 指针）：
/// 句柄属于本次检查专用的控制连接，只在后台线程里被调用一次；结果在主线程
/// 通过 `DispatchSemaphore` 建立 happens-before 之后读取，不存在并发访问。
private final class KillSender: @unchecked Sendable {
    let handle: OpaquePointer
    let threadId: UInt64

    var rc: Int32 = -1
    var code: UInt32 = 0
    var message = ""

    var ok: Bool { rc == MTL_OK }

    init(handle: OpaquePointer, threadId: UInt64) {
        self.handle = handle
        self.threadId = threadId
    }

    func send() {
        let sql = "KILL QUERY \(threadId)"
        var err = [CChar](repeating: 0, count: Int(MTL_ERRBUF_SIZE))
        rc = mtl_conn_query(handle, sql, sql.utf8.count, 0, nil, &err, err.count)
        code = mtl_conn_errno(handle)
        message = cStringBuf(err)
        if message.isEmpty { message = cString(mtl_conn_error(handle)) }
    }
}

// MARK: - 工具

private func cString(_ pointer: UnsafePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    return String(cString: pointer)
}

private func cStringBuf(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
