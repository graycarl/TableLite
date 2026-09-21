import Foundation

/// 建立一条 MySQL 连接所需的**自包含**参数。
///
/// 它不依赖 `Connection` 模型，也不持有 Keychain：密码由调用方按需取出后传入
/// （见 `docs/tech-designs/05-session-management.md` §1）。
///
/// 从 `MySQLConfig` 映射见 `init(config:password:)`，是纯函数，可单测。
public struct MySQLConnectionParameters: Sendable, Equatable, Hashable {

    public var host: String
    public var port: UInt32
    public var user: String
    /// 密码。只在内存里存在，不写入任何持久化文件。
    public var password: String
    public var database: String
    public var charset: String
    /// Unix socket 路径；非空时 libmysqlclient 优先走 socket。
    public var unixSocket: String?
    public var useSSL: Bool
    public var skipCertificateVerification: Bool
    /// 连接超时（秒）。
    public var connectTimeout: TimeInterval
    /// 读写超时（秒）；0 表示用库默认。见 `03-mysql-layer.md` §5。
    public var readWriteTimeout: TimeInterval
    /// 查询超时（秒）；超时后自动中止查询。
    public var queryTimeout: TimeInterval
    public var keepAlive: Bool
    /// 心跳间隔（秒）。定时器由上层驱动，session 只提供 `ping()`。
    public var keepAliveInterval: TimeInterval

    public init(
        host: String,
        port: UInt32 = 3306,
        user: String,
        password: String = "",
        database: String = "",
        charset: String = "utf8mb4",
        unixSocket: String? = nil,
        useSSL: Bool = true,
        skipCertificateVerification: Bool = false,
        connectTimeout: TimeInterval = 10,
        readWriteTimeout: TimeInterval = 0,
        queryTimeout: TimeInterval = 300,
        keepAlive: Bool = true,
        keepAliveInterval: TimeInterval = 30
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.charset = charset
        self.unixSocket = unixSocket
        self.useSSL = useSSL
        self.skipCertificateVerification = skipCertificateVerification
        self.connectTimeout = connectTimeout
        self.readWriteTimeout = readWriteTimeout
        self.queryTimeout = queryTimeout
        self.keepAlive = keepAlive
        self.keepAliveInterval = keepAliveInterval
    }

    /// 从连接模型映射。`password` 由调用方从 Keychain 取出。
    ///
    /// 端口与 socket 做归一化（非法端口回退 3306，空白 socket 视为 nil），与连接表单校验
    /// 的取值保持一致，避免把未校验的值直接交给 C 层。
    public init(config: MySQLConfig, password: String) {
        self.init(
            host: config.host,
            port: Self.normalizedPort(config.port),
            user: config.user,
            password: password,
            database: config.database,
            charset: config.charset,
            unixSocket: Self.normalizedSocket(config.unixSocket),
            useSSL: config.useSSL,
            skipCertificateVerification: config.skipCertificateVerification,
            connectTimeout: TimeInterval(config.connectTimeout),
            readWriteTimeout: 0,
            queryTimeout: TimeInterval(config.queryTimeout),
            keepAlive: config.keepAlive,
            keepAliveInterval: TimeInterval(config.keepAliveInterval)
        )
    }

    // MARK: 归一化（纯函数）

    /// 端口不在 1–65535 时回退 3306。
    public static func normalizedPort(_ port: Int) -> UInt32 {
        guard (1...65535).contains(port) else { return 3306 }
        return UInt32(port)
    }

    /// 空白字符串与 nil 统一成 nil。
    public static func normalizedSocket(_ socket: String?) -> String? {
        guard let socket else { return nil }
        let trimmed = socket.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : socket
    }

    /// `mtl_conn_set_connect_timeout` 需要 `unsigned int` 秒。
    public var connectTimeoutSeconds: UInt32 {
        Self.wholeSeconds(connectTimeout, fallback: 10)
    }

    /// 0 表示不设置（用库默认）。
    public var readWriteTimeoutSeconds: UInt32 {
        Self.wholeSeconds(readWriteTimeout, fallback: 0)
    }

    /// 连接列表里的一行摘要：`用户@主机:端口/数据库`。
    public var summary: String {
        let databasePart = database.isEmpty ? "" : "/\(database)"
        return "\(user)@\(host):\(port)\(databasePart)"
    }

    /// 时间间隔转整秒；非有限值或非正数取 `fallback`，并夹在 `UInt32` 范围内。
    public static func wholeSeconds(_ value: TimeInterval, fallback: UInt32) -> UInt32 {
        guard value.isFinite, value > 0 else { return fallback }
        let rounded = value.rounded()
        if rounded >= Double(UInt32.max) { return UInt32.max }
        return UInt32(rounded)
    }
}
