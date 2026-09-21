import Foundation

/// 按列名读取 `information_schema` 查询结果的小工具。
///
/// 文本协议返回的是原始字节，这里只做「按列名取值 + 基本解释」，
/// 不改变 `CellValue` 的语义（见 docs/tech-designs/03-mysql-layer.md §4.1）。
struct ResultRowReader {
    let columns: [ResultSetColumn]
    let values: [CellValue]

    private var indexByName: [String: Int] {
        var map: [String: Int] = [:]
        for (index, column) in columns.enumerated() where map[column.name] == nil {
            map[column.name] = index
        }
        return map
    }

    func value(_ name: String) -> CellValue? {
        guard let index = indexByName[name], index < values.count else { return nil }
        return values[index]
    }

    func string(_ name: String) -> String? {
        guard let value = value(name), !value.isNull else { return nil }
        return value.displayText
    }

    func nonEmptyString(_ name: String) -> String? {
        guard let text = string(name), !text.isEmpty else { return nil }
        return text
    }

    func int(_ name: String) -> Int? {
        guard let text = string(name) else { return nil }
        return Int(text)
    }

    func uint64(_ name: String) -> UInt64? {
        guard let text = string(name) else { return nil }
        return UInt64(text)
    }

    func bool(_ name: String) -> Bool? {
        guard let text = nonEmptyString(name)?.uppercased() else { return nil }
        return text == "YES" || text == "1" || text == "TRUE"
    }
}

extension MaterializedResultSet {
    /// 只保留有结果集的那些（跳过 OK 包）
    static func firstResultSet(in results: [MaterializedResultSet]) -> MaterializedResultSet? {
        results.first { $0.header.isResultSet }
    }

    var readers: [ResultRowReader] {
        rows.map { ResultRowReader(columns: header.columns, values: $0) }
    }
}
