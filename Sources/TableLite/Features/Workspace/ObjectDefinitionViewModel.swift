import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.graycarl.tablelite", category: "ui")

// MARK: - 对象定义 ViewModel

/// 对象定义标签的 ViewModel：只有一个只读的 DDL 文本。
///
/// 定义来源是 `MetaRepository.structure(_:).createStatement`（`SHOW CREATE TABLE` /
/// `SHOW CREATE VIEW`），见 `docs/tech-designs/11-schema-and-import-export.md` §1、
/// `specs/07-schema-view.md` §3。视图只读状态、只发意图。
///
/// 线程：`@MainActor`；元数据读取经 `MetaRepository`（actor），回主线程后再写 `@Published`。
@MainActor
final class ObjectDefinitionViewModel: ObservableObject {

    let ref: TableRef
    let kind: DatabaseObjectKind

    @Published private(set) var definition: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: MySQLError?

    private let meta: MetaRepository

    init(ref: TableRef, kind: DatabaseObjectKind, meta: MetaRepository) {
        self.ref = ref
        self.kind = kind
        self.meta = meta
    }

    // MARK: 加载

    /// 首次加载（已有内容则跳过）。视图在 `.task` 中调用。
    func load() async {
        guard definition == nil, !isLoading else { return }
        await fetch()
    }

    /// `⌘R` / 过期提示条里的「刷新」：失效缓存后重新读取。
    func refresh() async {
        await meta.invalidate(ref)
        await fetch()
    }

    private func fetch() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let structure = try await meta.structure(ref)
            definition = structure.createStatement
        } catch {
            logger.error("读取对象定义失败：\(String(describing: error), privacy: .public)")
            self.error = Self.mapError(error)
        }
    }

    private static func mapError(_ error: Error) -> MySQLError {
        if let mySQL = error as? MySQLError { return mySQL }
        return .internalError(String(describing: error))
    }
}
