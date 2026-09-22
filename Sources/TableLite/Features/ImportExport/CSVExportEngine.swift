import Foundation
import Synchronization

// MARK: - 取消阀

/// 导出取消阀。`onEvent` 回调在 MySQL 串行队列上执行，取消由 UI 线程触发，
/// 两边通过 `Mutex` 同步。
public final class ExportControl: Sendable {
    private let cancelled = Mutex(false)

    public init() {}

    public var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    public func cancel() {
        cancelled.withLock { $0 = true }
    }
}

// MARK: - 流式后端

/// 导出查询的流式后端。
public enum ExportStreamSource: Sendable {
    /// 走 `ConnectionSession.streamQuery`：统一记录查询历史与 Console Log。
    case session(ConnectionSession)
    /// 走裸 `MySQLSessionProtocol`（单测用）。
    case raw(any MySQLSessionProtocol)
}

// MARK: - 引擎

/// 导出执行引擎：不依赖 UI，逐事件写文件，全程 O(1) 内存。
///
/// 硬约束见 `docs/tech-designs/11-schema-and-import-export.md` §3.1：
/// unbuffered 查询 + 逐行写文件；成功原子替换，取消 / 中断保留 `.partial`。
public enum CSVExportEngine {

    /// 进度回调节流间隔（行）。
    public static let progressInterval = 500

    public static func run(
        plan: ExportPlan,
        sink: CSVExportSink,
        control: ExportControl,
        source: ExportStreamSource,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> ExportSummary {
        let state = StreamState(columns: plan.columns)

        // 表 / 选中行导出已知表头，先写。
        do {
            try sink.writeHeaderIfNeeded(plan.header)
        } catch {
            state.setError(Self.describe(error))
            control.cancel()
        }

        let onEvent: @Sendable (MySQLQueryEvent) -> Void = { event in
            guard !control.isCancelled else { return }
            switch event {
            case .resultSet(let header):
                guard !header.columns.isEmpty else { return }
                let adopted = state.adopt(header: header)
                if adopted {
                    do {
                        try sink.writeHeaderIfNeeded(header.columns.map(\.name))
                    } catch {
                        state.setError(Self.describe(error))
                        control.cancel()
                    }
                }

            case .row(let row):
                // 只导第一个带列的结果集。
                if let resultIndex = state.resultIndex, resultIndex != row.resultIndex {
                    return
                }
                let columns = state.columns
                let values = MySQLValueMapping.values(for: row, columns: columns)
                do {
                    try sink.append(values.map(CSVField.init))
                } catch {
                    state.setError(Self.describe(error))
                    control.cancel()
                    return
                }
                let snapshot = sink.snapshot()
                if snapshot.rowCount % progressInterval == 0 {
                    progress(snapshot.rowCount, snapshot.byteCount)
                }

            case .statementError(let statement):
                state.setError("[错误 \(statement.error.code)] \(statement.error.message)")
            }
        }

        var thrown: String?
        var wasCancelled = false
        do {
            let summary = try await stream(source: source, plan: plan, onEvent: onEvent)
            wasCancelled = summary.wasCancelled
        } catch {
            thrown = Self.describe(error)
            if let mysqlError = error as? MySQLError, mysqlError.isCancellation {
                wasCancelled = true
                thrown = nil
            }
        }

        let snapshot = sink.snapshot()
        let failure: String?
        if let stateError = state.errorMessage {
            failure = stateError
        } else {
            failure = thrown
        }
        let finalCancelled = wasCancelled || control.isCancelled

        if let failure {
            sink.abort()
            return ExportSummary(
                rowCount: snapshot.rowCount,
                byteCount: snapshot.byteCount,
                partialURL: sink.partialURL,
                wasCancelled: false,
                failureMessage: failure
            )
        }
        if finalCancelled {
            sink.abort()
            return ExportSummary(
                rowCount: snapshot.rowCount,
                byteCount: snapshot.byteCount,
                partialURL: sink.partialURL,
                wasCancelled: true
            )
        }

        do {
            try sink.finish()
            return ExportSummary(
                rowCount: snapshot.rowCount,
                byteCount: snapshot.byteCount,
                destinationURL: sink.targetURL
            )
        } catch {
            sink.abort()
            return ExportSummary(
                rowCount: snapshot.rowCount,
                byteCount: snapshot.byteCount,
                partialURL: sink.partialURL,
                failureMessage: Self.describe(error)
            )
        }
    }

    // MARK: 内部

    private static func stream(
        source: ExportStreamSource,
        plan: ExportPlan,
        onEvent: @escaping @Sendable (MySQLQueryEvent) -> Void
    ) async throws -> MySQLQuerySummary {
        switch source {
        case .session(let session):
            return try await session.streamQuery(
                plan.sql,
                database: plan.database,
                unbuffered: true,
                onEvent: onEvent
            )
        case .raw(let session):
            return try await session.streamQuery(plan.sql, unbuffered: true, onEvent: onEvent)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let exportError = error as? CSVExportError { return exportError.message }
        if let mysqlError = error as? MySQLError {
            return "[错误 \(mysqlError.code)] \(mysqlError.message)"
        }
        return String(describing: error)
    }

    /// 跨队列共享的流状态：列元数据、首个结果集下标、错误信息。
    private final class StreamState: Sendable {
        private struct Inner {
            var columns: [ColumnInfo]
            var resultIndex: Int?
            var errorMessage: String?
        }

        private let mutex: Mutex<Inner>

        init(columns: [ColumnInfo]) {
            mutex = Mutex(Inner(columns: columns, resultIndex: nil, errorMessage: nil))
        }

        var columns: [ColumnInfo] {
            mutex.withLock { $0.columns }
        }

        var resultIndex: Int? {
            mutex.withLock { $0.resultIndex }
        }

        var errorMessage: String? {
            mutex.withLock { $0.errorMessage }
        }

        func setError(_ message: String) {
            mutex.withLock { state in
                if state.errorMessage == nil { state.errorMessage = message }
            }
        }

        /// 采用第一个结果集的列；返回是否是首次采用。
        func adopt(header: MySQLResultSetHeader) -> Bool {
            mutex.withLock { state in
                guard state.resultIndex == nil else { return false }
                state.resultIndex = header.index
                state.columns = header.columns
                return true
            }
        }
    }
}
