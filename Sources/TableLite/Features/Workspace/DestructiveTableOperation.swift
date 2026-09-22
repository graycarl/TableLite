import SwiftUI

/// 对象树里直接生效（不进变更暂存）的破坏性操作。
///
/// 需求见 `specs/02-workspace.md` §5「破坏性操作」：只读连接下禁用；
/// 弹窗先展示将要执行的 SQL；必须手动输入表名才能确认。
enum DestructiveTableOperation: Identifiable, Equatable {
    case truncate(database: String, table: String)
    case drop(database: String, table: String)

    var id: String {
        switch self {
        case .truncate(let database, let table): return "truncate.\(database).\(table)"
        case .drop(let database, let table): return "drop.\(database).\(table)"
        }
    }

    var database: String {
        switch self {
        case .truncate(let database, _), .drop(let database, _): return database
        }
    }

    var table: String {
        switch self {
        case .truncate(_, let table), .drop(_, let table): return table
        }
    }

    var title: String {
        switch self {
        case .truncate: return "截断表"
        case .drop: return "删除表"
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .truncate: return "截断"
        case .drop: return "删除"
        }
    }

    var symbolName: String {
        switch self {
        case .truncate: return "eraser"
        case .drop: return "trash"
        }
    }

    /// 将要执行的 SQL（弹窗展示与真正下发共用同一条）。
    var sql: String {
        let qualified = SQLIdentifier.qualified(database: database, table: table)
        switch self {
        case .truncate: return "TRUNCATE TABLE \(qualified);"
        case .drop: return "DROP TABLE \(qualified);"
        }
    }
}

/// 截断 / 删除表的确认弹窗。
struct DestructiveTableOperationSheet: View {

    let operation: DestructiveTableOperation
    let session: ConnectionSession
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typedTableName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(operation.title, systemImage: operation.symbolName)
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("将要执行：")
                Text(operation.sql)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text("该操作不可撤销，且无法通过「放弃改动」回退。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("请输入表名 \(operation.table) 以确认：")
                TextField(operation.table, text: $typedTableName)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
                Button(operation.confirmButtonTitle, role: .destructive) { perform() }
                    .disabled(typedTableName != operation.table)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func perform() {
        Task {
            do {
                _ = try await session.execute(operation.sql)
                onCompleted()
                dismiss()
            } catch {
                errorMessage = "执行失败：\(error)"
            }
        }
    }
}
