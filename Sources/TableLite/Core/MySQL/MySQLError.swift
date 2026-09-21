import Foundation

/// MySQL 访问层的统一错误类型。
///
/// 规则见 `docs/tech-designs/03-mysql-layer.md` §7、`01-architecture.md` §4：
/// - 服务器原始 `code` / `SQLSTATE` / `message` **原样保留**，不翻译；
/// - 另外映射出一个中文解释行与分类，供 UI 决定文案；
/// - 连接类错误不会与「服务器返回 1049 库不存在」混为一谈。
///
/// 分类逻辑是纯函数，见 `classify(code:)`。
public struct MySQLError: Error, Sendable, Equatable, CustomStringConvertible {

    // MARK: 分类

    /// 错误大致分三层：客户端调用问题 / 连接层 / 服务器执行层。
    ///
    /// 连接类与执行类分开，是为了让 UI 文案不把「服务器返回语法错误」说成「连接失败」
    /// （`03-mysql-layer.md` §7）。
    public enum Category: Sendable, Equatable {
        case client
        case connection
        case execution
    }

    /// 具体错误种类。
    public enum Kind: Sendable, Equatable {
        /// 尚未连接或已断开。
        case notConnected
        /// 上层调用参数不合法。
        case invalidInput
        /// 网络 / 握手 / DNS 等建连失败（2002 / 2003 / 2005 等）。
        case connectionFailed
        /// 用户名或密码错误（1045 等）。
        case authentication
        /// 库不存在（1049）。连接本身成功，只是配置里的库不可用。
        case unknownDatabase
        /// 服务器断开（2006 / 2013）。
        case serverGone
        /// SQL 语法错误（1064 等）。
        case syntax
        /// 权限不足（1044 / 1142 / 1143 / 1227 / 1370 等）。
        case permission
        /// 查询被中断（1317 / 1927）。
        case interrupted
        /// 客户端超时中止（由 `MySQLSession` 的 `queryTimeout` 触发）。
        case timeout
        /// 违反唯一键 / 约束（1062 等）。
        case constraintViolation
        /// 锁等待超时（1205）。
        case lockWaitTimeout
        /// 死锁（1213）。
        case deadlock
        /// 表或视图不存在（1146）。
        case unknownTable
        /// 服务器上找不到线程（1094）：`KILL QUERY` 时查询已经结束。
        case unknownThread
        /// 其余服务器错误。
        case server
    }

    // MARK: 字段

    public let kind: Kind
    /// 服务器错误码；客户端侧错误为 0。
    public let code: UInt32
    /// `SQLSTATE`；不可用时为空串。
    public let sqlState: String
    /// 服务器返回的原文，或客户端侧的说明。
    public let message: String
    /// 出错语句的前 200 字符（`03-mysql-layer.md` §7）。
    public let statement: String?

    public init(
        kind: Kind,
        code: UInt32,
        sqlState: String,
        message: String,
        statement: String? = nil
    ) {
        self.kind = kind
        self.code = code
        self.sqlState = sqlState
        self.message = message.isEmpty ? "（没有错误详情）" : message
        self.statement = statement.map { String($0.prefix(200)) }
    }

    // MARK: 派生属性

    public var category: Category {
        switch kind {
        case .notConnected, .invalidInput:
            return .client
        case .connectionFailed, .authentication, .unknownDatabase, .serverGone, .unknownThread:
            return .connection
        default:
            return .execution
        }
    }

    /// `2006` / `2013`：连接已失效，上层需要提示「重新连接」。
    ///
    /// 见 `docs/tech-designs/05-session-management.md` §6。
    public var isConnectionLost: Bool { kind == .serverGone }

    /// 是否属于「连都连不上」类错误。
    ///
    /// `1049`（库不存在）**不算**连接失败：连接本身是成功的（`03-mysql-layer.md` §7）。
    public var isConnectionFailure: Bool {
        switch kind {
        case .connectionFailed, .authentication:
            return true
        default:
            return false
        }
    }

    /// 是否属于「已取消 / 超时」，UI 不应按未知错误弹窗（`03-mysql-layer.md` §5）。
    public var isCancellation: Bool { kind == .interrupted || kind == .timeout }

    /// 中文解释行。与服务器原文一起展示。
    public var chineseExplanation: String {
        switch kind {
        case .notConnected:
            return "连接尚未建立或已经断开。"
        case .invalidInput:
            return "调用参数不合法。"
        case .connectionFailed:
            return "无法建立连接：请检查主机、端口、网络与防火墙。"
        case .authentication:
            return "认证失败：用户名或密码不正确，或该用户不允许从本机登录。"
        case .unknownDatabase:
            return "连接配置里的数据库不存在。连接本身是成功的。"
        case .serverGone:
            return "与服务器的连接已断开，需要重新连接。"
        case .syntax:
            return "SQL 语法错误。"
        case .permission:
            return "当前账号没有执行该操作的权限。"
        case .interrupted:
            return "查询已取消。"
        case .timeout:
            return "查询超时，已自动中止。"
        case .constraintViolation:
            return "违反唯一键或其它约束，数据未写入。"
        case .lockWaitTimeout:
            return "等待行锁超时。"
        case .deadlock:
            return "检测到死锁，事务已回滚。"
        case .unknownTable:
            return "表或视图不存在。"
        case .unknownThread:
            return "服务器上找不到该连接线程，查询可能已经结束。"
        case .server:
            return "服务器返回错误（错误码 \(code)）。"
        }
    }

    public var description: String {
        var text = "\(message) [code=\(code) sqlstate=\(sqlState.isEmpty ? "-" : sqlState)]"
        if let statement, !statement.isEmpty {
            text += " ← \(statement)"
        }
        return text
    }

    // MARK: 构造 / 映射

    /// 按错误码分类。纯函数，可单测。
    public static func classify(code: UInt32) -> Kind {
        switch code {
        case 2002, 2003, 2005:
            return .connectionFailed
        case 2006, 2013:
            return .serverGone
        case 1045:
            return .authentication
        case 1049:
            return .unknownDatabase
        case 1044, 1142, 1143, 1227, 1370:
            return .permission
        case 1062:
            return .constraintViolation
        case 1064:
            return .syntax
        case 1094:
            return .unknownThread
        case 1146:
            return .unknownTable
        case 1205:
            return .lockWaitTimeout
        case 1213:
            return .deadlock
        case 1317, 1927:
            return .interrupted
        default:
            return .server
        }
    }

    /// 由服务器错误码构造。
    public static func server(
        code: UInt32,
        sqlState: String,
        message: String,
        statement: String? = nil
    ) -> MySQLError {
        MySQLError(
            kind: classify(code: code),
            code: code,
            sqlState: sqlState,
            message: message,
            statement: statement
        )
    }

    /// 由建连失败构造：能识别到具体错误码时用识别结果，否则归为连接失败。
    public static func connectionFailure(
        code: UInt32,
        sqlState: String,
        message: String
    ) -> MySQLError {
        let kind: Kind
        switch code {
        case 1045, 1049, 2006, 2013:
            kind = classify(code: code)
        default:
            kind = .connectionFailed
        }
        return MySQLError(kind: kind, code: code, sqlState: sqlState, message: message)
    }

    /// 尚未连接 / 连接不可用。
    public static func notConnected(statement: String? = nil) -> MySQLError {
        MySQLError(kind: .notConnected, code: 0, sqlState: "", message: "连接不可用", statement: statement)
    }

    /// 客户端侧取消了查询（未拿到服务器错误码）。
    public static func cancelled(timedOut: Bool, statement: String? = nil) -> MySQLError {
        MySQLError(
            kind: timedOut ? .timeout : .interrupted,
            code: 0,
            sqlState: "",
            message: timedOut ? "查询超时，已自动中止" : "查询已取消",
            statement: statement
        )
    }
}
