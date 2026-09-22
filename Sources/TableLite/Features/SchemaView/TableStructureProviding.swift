import Foundation

/// 表结构视图的数据来源。
///
/// 抽成协议是为了让 `TableStructureViewModel` 的单测能注入替身；
/// 生产实现直接转发给 `MetaRepository`，不新增任何缓存或查询
/// （见 `docs/tech-designs/11-schema-and-import-export.md` §1）。
protocol TableStructureProviding: Sendable {
    func loadStructure(
        database: String,
        table: String,
        kind: TableKind,
        forceRefresh: Bool
    ) async throws -> TableStructure
}

/// 走 `MetaRepository` 的生产实现。
struct LiveTableStructureProvider: TableStructureProviding {

    private let repository: MetaRepository

    init(repository: MetaRepository) {
        self.repository = repository
    }

    func loadStructure(
        database: String,
        table: String,
        kind: TableKind,
        forceRefresh: Bool
    ) async throws -> TableStructure {
        try await repository.structure(
            database: database,
            table: table,
            kind: kind,
            forceRefresh: forceRefresh
        )
    }
}
