import Combine
import Foundation
import os

// MARK: - ConsoleLogViewModel

/// Console Log 面板的 ViewModel。见 `docs/tech-designs/02-persistence.md` §5、
/// `specs/06-query-editor.md` §6。
///
/// - 直接观察注入的 `ConsoleLogStore`（环形缓冲 + 可选落盘）；
/// - `[data]` 由查询标签写入，`[meta]` 由元数据模块写入，本 VM 只做过滤与展示；
/// - `entries` 是过滤 + 搜索后的视图，`textDump` 与之一致（复制可见内容）。
@MainActor
final class ConsoleLogViewModel: ObservableObject {

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case data
        case meta

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "全部"
            case .data: return "仅数据语句"
            case .meta: return "仅元数据"
            }
        }
    }

    @Published var filter: Filter = .all {
        didSet { reload() }
    }

    @Published var searchText: String = "" {
        didSet { reload() }
    }

    @Published private(set) var entries: [ConsoleLogStore.Entry] = []

    private let store: ConsoleLogStore
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "mysql")
    private let timestampFormatter: DateFormatter
    private var cancellable: AnyCancellable?

    init(store: ConsoleLogStore) {
        self.store = store

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.timestampFormatter = formatter

        // store 的 `entries` 是 `@Published`，订阅后即可自动跟随底部。
        cancellable = store.$entries.sink { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
        reload()
    }

    /// 按 `filter` + `searchText` 重新计算可见条目。
    func reload() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        entries = store.entries.filter { entry in
            switch filter {
            case .all:
                break
            case .data where entry.category != .data:
                return false
            case .meta where entry.category != .meta:
                return false
            default:
                break
            }
            guard !query.isEmpty else { return true }
            return entry.sql.lowercased().contains(query)
        }
    }

    func clear() {
        store.clear()
        reload()
        logger.debug("Console Log 已清空")
    }

    /// 复制用：与当前过滤视图一致。
    var textDump: String {
        entries.map { line(for: $0) }.joined(separator: "\n")
    }

    // MARK: 私有

    private func line(for entry: ConsoleLogStore.Entry) -> String {
        var text = "[\(timestampFormatter.string(from: entry.timestamp))] [\(entry.category.rawValue)] "
        if let database = entry.database, !database.isEmpty {
            text += "(\(database)) "
        }
        text += "\(QueryTabLogic.elapsedText(entry.elapsed)) "
        text += entry.sql.replacingOccurrences(of: "\n", with: " ")
        if let errorCode = entry.errorCode {
            text += " → 错误 \(errorCode)"
            if let message = entry.errorMessage, !message.isEmpty {
                text += "：\(message.replacingOccurrences(of: "\n", with: " "))"
            }
        } else if let affectedRows = entry.affectedRows {
            text += " → 影响 \(affectedRows) 行"
        } else if let rowCount = entry.rowCount {
            text += " → \(rowCount) 行"
        }
        return text
    }
}
