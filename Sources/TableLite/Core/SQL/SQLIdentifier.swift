import Foundation

/// SQL 标识符引用。MySQL 用反引号，内部反引号双写。
///
/// 纯函数，见 `docs/tech-designs/03-mysql-layer.md` §4.2 与 `08-pending-changes.md` §3。
public enum SQLIdentifier {
    /// 用反引号包裹一个标识符。`` a`b `` → `` `a``b` ``。
    public static func quote(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// `` `database`.`table` ``；database 为空时只引用表名。
    public static func qualified(database: String?, table: String) -> String {
        guard let database, !database.isEmpty else { return quote(table) }
        return "\(quote(database)).\(quote(table))"
    }

    /// 逗号分隔的引用列名列表。
    public static func quoteList(_ names: [String]) -> String {
        names.map(quote).joined(separator: ", ")
    }
}
