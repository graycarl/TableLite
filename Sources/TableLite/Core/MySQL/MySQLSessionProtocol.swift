import Foundation

/// `MySQLSession` 的**最小协议面**。
///
/// 目的：让上层（`MetaRepository`、`ConnectionSession`）依赖抽象而不是具体 actor，
/// 单测可以注入假实现；线程模型、串行队列、C 回调只复制数据等硬约束仍由
/// `MySQLSession` 本体承担（`docs/tech-designs/01-architecture.md` §3）。
///
/// 协议是 `Sendable`：`MySQLSession` 是 actor，跨隔离域传递安全。
/// `escape` / `makeEscaper` / `charsetIntroducer` 在 `MySQLSession` 上是 `nonisolated`，
/// 因此可以被同步调用（生成字面量时不能 `await`）。
public protocol MySQLSessionProtocol: Sendable {

    // MARK: 生命周期

    func connect(_ parameters: MySQLConnectionParameters) async throws
    func disconnect() async
    func reconnect() async throws
    /// 保活心跳；失败时抛 `MySQLError`（`2006` / `2013` 可被上层识别为连接失效）。
    func ping() async throws

    // MARK: 执行

    /// 缓冲执行一段 SQL，返回全部结果集。
    func execute(_ sql: String, unbuffered: Bool) async throws -> MySQLQueryResult

    /// 流式执行；回调在 session 的串行队列上同步执行，只应做数据复制或计数。
    func streamQuery(
        _ sql: String,
        unbuffered: Bool,
        onEvent: @escaping @Sendable (MySQLQueryEvent) -> Void
    ) async throws -> MySQLQuerySummary

    /// 取消当前查询。
    func cancel() async throws

    // MARK: 转义（同步，生成字面量用）

    func escape(_ text: String) -> String
    func makeEscaper() -> SQLValueLiteral.StringEscaper
    var charsetIntroducer: String? { get }

    // MARK: 状态

    var state: MySQLSession.State { get async }
    /// 配置里的库不存在（`1049`）时记录库名；连接本身成功。
    var unresolvedDatabase: String? { get async }
    var currentParameters: MySQLConnectionParameters? { get async }

    // MARK: 服务器信息（可选能力）

    /// 服务器线程 id，用于诊断。
    var serverThreadID: UInt64 { get async }
}

extension MySQLSession: MySQLSessionProtocol {}
