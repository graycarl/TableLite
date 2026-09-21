import Foundation

// MARK: - SQL 标识符引用
//
// 纯函数。规则：用反引号包裹，内部反引号转义为两个反引号。
// 见 docs/tech-designs/09-filtering.md §1.4。

enum SQLIdentifier {

    /// `` `name` ``，内部反引号转义为两个反引号。
    static func quote(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

    /// `` `db`.`table` ``
    static func qualified(_ database: String, _ table: String) -> String {
        "\(quote(database)).\(quote(table))"
    }

    /// 逗号连接（每项单独引用）。
    static func list(_ names: [String]) -> String {
        names.map(quote).joined(separator: ", ")
    }
}
