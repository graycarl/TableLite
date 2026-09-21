import Foundation

// MARK: - 表数据加载错误

/// 表数据加载层可识别的错误。
enum TableDataLoaderError: Error, Hashable, Sendable {
    /// 二次加载大字段时，行已不存在（很可能已被外部删除）。
    case rowMissing

    var message: String {
        switch self {
        case .rowMissing: return "该行已不存在，可能已被删除"
        }
    }
}

// MARK: - 表数据加载

/// 表数据分页加载：把 `TableDataQueryBuilder` 生成的 SQL 经 `MySQLSession` 下发，
/// 再把结果集按投影位置组装成 `TableDataRow`。
///
/// 本层不写 Console Log（由调用方决定）。
struct TableDataLoader: Sendable {

    let session: MySQLSession
    /// 元数据与行数估算缓存（见 docs/tech-designs/11-schema-and-import-export.md §1）。
    let meta: MetaRepository

    init(session: MySQLSession, meta: MetaRepository) {
        self.session = session
        self.meta = meta
    }

    // MARK: 分页

    func loadPage(ref: TableRef,
                  structure: TableStructure,
                  request: TablePageRequest,
                  lazyLarge: Bool,
                  largeThreshold: Int) async throws -> TableDataPage {
        let clock = ContinuousClock()
        let started = clock.now

        let literalizer = await session.literalizer()
        let projections = TableDataQueryBuilder.projection(
            structure: structure,
            lazyLarge: lazyLarge,
            largeThreshold: largeThreshold
        )
        let sql = try TableDataQueryBuilder.pageSQL(
            ref: ref,
            structure: structure,
            request: request,
            lazyLarge: lazyLarge,
            largeThreshold: largeThreshold,
            literalizer: literalizer
        )

        let results = try await session.queryAll(sql, unbuffered: false)
        guard let resultSet = MaterializedResultSet.firstResultSet(in: results) else {
            throw MySQLError.internalError("分页查询没有返回结果集")
        }

        let primaryKeyNames = structure.primaryKeyColumns.map(\.name)
        let hasPrimaryKey = !primaryKeyNames.isEmpty
        let primaryKeyIndexes = primaryKeyNames.compactMap { name in
            projections.firstIndex { $0.tableColumnName == name }
        }
        let truncatedProjections = projections
            .filter(\.isTruncated)
            .enumerated()
            .map { (lengthOffset: $0.offset, projection: $0.element) }
        let effectiveThreshold = max(largeThreshold, 1)

        let pageSize = max(request.pageSize, 0)
        var rows: [TableDataRow] = []
        rows.reserveCapacity(min(resultSet.rows.count, pageSize))

        for (rowIndex, rawRow) in resultSet.rows.enumerated() {
            guard rawRow.count >= projections.count else {
                throw MySQLError.internalError("分页查询返回的列数与投影不一致")
            }
            let values = Array(rawRow.prefix(projections.count))

            var truncatedLengths: [String: Int] = [:]
            for entry in truncatedProjections {
                let position = projections.count + entry.lengthOffset
                guard position < rawRow.count else { continue }
                guard let text = rawRow[position].strictText, let length = Int(text) else { continue }
                // 只有真的被截断（真实长度 > 阈值）才记录；否则值本身就是完整的。
                if length > effectiveThreshold {
                    truncatedLengths[entry.projection.tableColumnName] = length
                }
            }

            let identity: RowIdentity
            if hasPrimaryKey, primaryKeyIndexes.count == primaryKeyNames.count {
                let keyValues = primaryKeyIndexes.map { values[$0] }
                identity = .existing(RowIdentity.key(values: keyValues))
            } else {
                // 无主键：分页顺序不保证，用「页码 + 行号」当临时身份，仅用于本页展示。
                identity = .existing("row:\(request.pageIndex):\(rowIndex)")
            }

            rows.append(TableDataRow(identity: identity,
                                     values: values,
                                     truncatedLengths: truncatedLengths))
        }

        let hasNextPage = rows.count > pageSize
        if hasNextPage {
            rows.removeLast(rows.count - pageSize)
        }

        let rowEstimate = try? await meta.rowEstimate(ref)
        let elapsed = started.duration(to: clock.now)

        return TableDataPage(rows: rows,
                             hasNextPage: hasNextPage,
                             rowEstimate: rowEstimate,
                             elapsed: elapsed,
                             primaryKeyColumns: primaryKeyNames,
                             hasPrimaryKey: hasPrimaryKey)
    }

    // MARK: 大字段二次加载

    /// 取一行里指定列的完整值（字段栏 / 快速查看 / 开始编辑时用）。
    ///
    /// 行已不存在时抛 `TableDataLoaderError.rowMissing`，UI 提示「该行已不存在，可能已被删除」。
    func loadFullValues(ref: TableRef,
                        structure: TableStructure,
                        locator: RowLocator,
                        columns: [TableColumn]) async throws -> [String: CellValue] {
        let literalizer = await session.literalizer()
        let sql = TableDataQueryBuilder.fullValueSQL(
            ref: ref,
            structure: structure,
            locator: locator,
            columns: columns,
            literalizer: literalizer
        )

        let results = try await session.queryAll(sql, unbuffered: false)
        guard let resultSet = MaterializedResultSet.firstResultSet(in: results),
              let row = resultSet.rows.first else {
            throw TableDataLoaderError.rowMissing
        }

        var output: [String: CellValue] = [:]
        for (index, column) in resultSet.header.columns.enumerated() where index < row.count {
            output[column.name] = row[index]
        }
        return output
    }

    // MARK: 精确统计

    /// 真正的 `COUNT(*)`。只在用户点「精确统计」时执行，打开表时绝不自动跑。
    /// 走 `MetaRepository`，与元数据缓存共用同一套 SQL 规则。
    func preciseCount(ref: TableRef, whereClause: String?) async throws -> UInt64 {
        try await meta.preciseCount(ref, whereClause: whereClause)
    }
}
