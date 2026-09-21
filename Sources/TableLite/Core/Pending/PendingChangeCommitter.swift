import Foundation

// MARK: - 变更暂存的提交
//
// 在一个事务里**逐条**下发语句（不用一次性脚本，便于精确定位失败语句）。
// 见 docs/tech-designs/08-pending-changes.md §5 与 specs/04-data-editing.md §10。
//
// 硬约束：
// - 不改变会话的 autocommit（`BEGIN` 即隐式关闭，`COMMIT` / `ROLLBACK` 后自然恢复）；
// - 任一条失败 → 尽力 `ROLLBACK`，抛 `CommitFailure`，暂存不清空（由调用方决定）；
// - 影响 0 行视为成功，只记入 `CommitOutcome.zeroRowStatements`（幂等）；
// - Task 取消 → 在语句之间 `ROLLBACK` 并抛出 `CancellationError`。

struct PendingChangeCommitter: Sendable {

    /// 防御性检查拒绝非 DML 语句时的提示（唯一真源）。
    static let unsupportedStatementMessage = "变更暂存不应包含结构变更语句，请改用 SQL 编辑器执行"

    private let session: MySQLSession

    init(session: MySQLSession) {
        self.session = session
    }

    /// 逐条下发并以事务包住。
    /// - Parameter onProgress: `onProgress(已完成条数, 总数)`，每条成功后回调一次。
    func commit(
        _ statements: [PendingSQLStatement],
        clock: Clock,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> CommitOutcome {
        // 1) 空暂存 → 直接返回，连事务都不开
        guard !statements.isEmpty else {
            return CommitOutcome(executedCount: 0, elapsed: .zero)
        }

        // 2) 防御性检查：暂存只应由编辑操作生成；出现别的语句直接拒绝
        for statement in statements where !Self.isDML(statement.text) {
            throw MySQLError.unsupported(Self.unsupportedStatementMessage)
        }

        let startedAt = clock.now
        var executedCount = 0
        var zeroRowStatements: [Int] = []

        try await session.execute("BEGIN")

        for (offset, statement) in statements.enumerated() {
            // 3) 取消：在语句之间停下来并回滚
            if Task.isCancelled {
                await rollback()
                throw CancellationError()
            }

            do {
                let header = try await session.execute(statement.text)
                // 影响 0 行视为成功（行已被别处删除等），仅记录
                if header.affectedRows == 0 {
                    zeroRowStatements.append(offset + 1)
                }
            } catch is CancellationError {
                await rollback()
                throw CancellationError()
            } catch {
                // 用户取消（含服务器 1317 / 1927）→ 回滚后按取消处理；
                // 超时不算取消：事务状态未知，交由 CommitFailure 表达
                if Self.isUserCancellation(error) {
                    await rollback()
                    throw CancellationError()
                }
                let (serverError, stateUnknown) = Self.serverError(from: error)
                let rolledBack = await rollback()
                throw CommitFailure(
                    statementIndex: offset + 1,
                    totalStatements: statements.count,
                    error: serverError,
                    statement: statement.text,
                    transactionStateUnknown: stateUnknown || !rolledBack,
                    rolledBack: rolledBack
                )
            }

            executedCount += 1
            onProgress(executedCount, statements.count)
        }

        do {
            try await session.execute("COMMIT")
        } catch {
            let (serverError, _) = Self.serverError(from: error)
            _ = await rollback()
            throw CommitFailure(
                statementIndex: statements.count,
                totalStatements: statements.count,
                error: serverError,
                statement: "COMMIT",
                transactionStateUnknown: true,
                rolledBack: false
            )
        }

        let elapsedSeconds = clock.now.timeIntervalSince(startedAt)
        let elapsed = Duration.microseconds(Int64((elapsedSeconds * 1_000_000).rounded()))
        return CommitOutcome(
            executedCount: executedCount,
            elapsed: elapsed,
            zeroRowStatements: zeroRowStatements
        )
    }

    // MARK: - 内部

    private func rollback() async -> Bool {
        do {
            try await session.execute("ROLLBACK")
            return true
        } catch {
            // 连接已断 / 服务器崩溃时回滚可能失败；调用方据此判定事务状态
            return false
        }
    }

    /// 是否为用户主动取消（区别于超时：超时的事务状态未知）。
    private static func isUserCancellation(_ error: Error) -> Bool {
        guard let mySQL = error as? MySQLError else { return false }
        if case .cancelled = mySQL { return true }
        if case .server(let serverError) = mySQL, serverError.isCancelled { return true }
        return false
    }

    /// 语句是否以 INSERT / UPDATE / DELETE 开头（忽略前导空白，大小写不敏感）。
    static func isDML(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        for keyword in ["INSERT", "UPDATE", "DELETE"] {
            if trimmed.count >= keyword.count,
               trimmed.prefix(keyword.count).uppercased() == keyword {
                return true
            }
        }
        return false
    }

    /// 把底层错误映射成 `CommitFailure.error`，并判断事务状态是否未知。
    private static func serverError(from error: Error) -> (MySQLServerError, Bool) {
        guard let mySQL = error as? MySQLError else {
            return (MySQLServerError(code: 0,
                                     sqlState: "",
                                     message: String(describing: error),
                                     sql: nil), true)
        }
        switch mySQL {
        case .server(let serverError):
            // 服务器明确报错 → 事务状态已知，可回滚
            return (serverError, false)
        case .connectionLost(let serverError):
            let fallback = MySQLServerError(code: 2013,
                                            sqlState: "",
                                            message: mySQL.title,
                                            sql: nil)
            return (serverError ?? fallback, true)
        case .timeout:
            return (MySQLServerError(code: 0,
                                     sqlState: "",
                                     message: "提交超时",
                                     sql: nil), true)
        case .cancelled:
            return (MySQLServerError(code: 1317,
                                     sqlState: "",
                                     message: "查询已取消",
                                     sql: nil), true)
        default:
            // notConnected / connect / unsupported / internalError 等
            return (MySQLServerError(code: 0,
                                     sqlState: "",
                                     message: mySQL.title,
                                     sql: nil), true)
        }
    }
}
