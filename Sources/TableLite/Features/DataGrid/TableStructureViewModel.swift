import Combine
import Foundation
import os

// MARK: - 表结构子页签

/// 表结构视图的顶部子页签。视图只有 `.columns` / `.definition`（specs/07-schema-view.md §3）。
enum StructureSection: String, CaseIterable, Identifiable, Sendable {
    case columns
    case indexes
    case foreignKeys
    case triggers
    case createStatement
    case definition

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .columns: return "列"
        case .indexes: return "索引"
        case .foreignKeys: return "外键"
        case .triggers: return "触发器"
        case .createStatement: return "建表语句"
        case .definition: return "定义"
        }
    }
}

// MARK: - 表结构 ViewModel
//
// 表结构是只读的：只看、只复制，不在这里改（specs/07-schema-view.md）。
// 设计依据：docs/tech-designs/11-schema-and-import-export.md §1、specs/07-schema-view.md。
//
// 线程：`@MainActor`；元数据读取经 `MetaRepository`（actor），回主线程后再写 `@Published`。

@MainActor
final class TableStructureViewModel: ObservableObject {

    let ref: TableRef
    /// 连接是否处于只读模式。结构视图本身只读，这里保留给视图做提示。
    let isReadOnly: Bool

    @Published private(set) var structure: TableStructure?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: MySQLError?
    @Published var selectedSection: StructureSection = .columns

    private let meta: MetaRepository
    private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "mysql")

    init(ref: TableRef, meta: MetaRepository, isReadOnly: Bool) {
        self.ref = ref
        self.meta = meta
        self.isReadOnly = isReadOnly
    }

    // MARK: - 加载

    /// 首次加载结构（已有则跳过）。
    func load() async {
        guard structure == nil else { return }
        await fetch()
    }

    /// `⌘R`：失效缓存后重新读取结构。
    func refresh() async {
        await meta.invalidate(ref)
        await fetch()
    }

    private func fetch() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let loaded = try await meta.structure(ref)
            structure = loaded
            if !availableSections.contains(selectedSection) {
                selectedSection = .columns
            }
        } catch {
            logger.error("读取表结构失败：\(String(describing: error), privacy: .public)")
            loadError = mapError(error)
        }
    }

    // MARK: - 派生状态

    /// 视图只有「列」与「定义」两页（specs/07 §3）。
    var availableSections: [StructureSection] {
        guard let structure else { return StructureSection.allCases }
        if structure.kind == .view {
            return [.columns, .definition]
        }
        return [.columns, .indexes, .foreignKeys, .triggers, .createStatement]
    }

    /// `11 列 · 3 索引 · 1 外键 · 0 触发器`
    var statusSummary: String {
        guard let structure else { return "" }
        return "\(structure.columns.count) 列 · \(structure.indexes.count) 索引"
            + " · \(structure.foreignKeys.count) 外键 · \(structure.triggers.count) 触发器"
    }

    // MARK: - 内部

    private func mapError(_ error: Error) -> MySQLError {
        if let mySQL = error as? MySQLError { return mySQL }
        return .internalError(String(describing: error))
    }
}
