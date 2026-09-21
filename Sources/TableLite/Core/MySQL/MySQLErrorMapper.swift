import Foundation

/// 错误映射规则。集中处理两件事：
///
/// 1. 服务器错误码 `1317`（`ER_QUERY_INTERRUPTED`）/ `1927`（`ER_QUERY_TIMEOUT`）
///    一律映射为取消 / 超时，不当作未知错误弹窗 —— 见 `docs/tech-designs/03-mysql-layer.md` §5；
/// 2. 连接类错误与执行类错误分开，`SQLSTATE` / `code` / `message` 原样保留 —— 见同文 §7。
///
/// 注意：`1049`（未知数据库）**不是连接失败**，连接本身是成功的，按服务器错误展示，
/// 由 `MySQLServerError.chineseHint` 附中文解释。
enum MySQLErrorMapper {

    /// `MySQLServerError.sql` 保留的出错语句长度上限（字符）。
    static let sqlPrefixLimit = 200

    /// 服务器错误码 → 取消 / 超时。`nil` 表示不是取消语义。
    static func cancellation(fromServerCode code: UInt32) -> MySQLError? {
        switch code {
        case 1317: return .cancelled
        case 1927: return .timeout
        default: return nil
        }
    }

    static func serverError(code: UInt32,
                            sqlState: String,
                            message: String,
                            sql: String?) -> MySQLServerError {
        MySQLServerError(code: code, sqlState: sqlState, message: message, sql: sql)
    }

    /// `mysql_real_query` 直接失败（C shim 不会回调 `on_statement_error`）时的映射。
    static func queryFailure(errno: UInt32, sqlState: String, message: String, sql: String?) -> MySQLError {
        if let cancellation = cancellation(fromServerCode: errno) {
            return cancellation
        }
        return .server(serverError(code: errno, sqlState: sqlState, message: message, sql: sql))
    }

    /// 连接建立 / 保活失败。`detail` 留给 SSH stderr 之类的底层原始输出。
    static func connectFailure(step: ConnectStep, message: String, detail: String? = nil) -> MySQLError {
        .connect(step: step,
                 message: message.isEmpty ? "\(step.displayName)失败" : message,
                 detail: detail)
    }

    /// 出错语句的前 200 字符。
    static func sqlPrefix(_ sql: String) -> String {
        String(sql.prefix(sqlPrefixLimit))
    }

    /// 由原始字段构造带 sql 前缀的服务器错误。
    static func serverError(errno: UInt32,
                            sqlState: String,
                            message: String,
                            sqlPrefix: String?) -> MySQLServerError {
        MySQLServerError(code: errno, sqlState: sqlState, message: message, sql: sqlPrefix)
    }
}
