# 05 · 连接会话管理

需求见 [`specs/01-connections.md`](../../specs/01-connections.md)。本文只讲实现。

## 1. 模型

```swift
struct Connection: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var colorHex: String?          // nil = 默认色
    var readOnly: Bool             // 见 specs/09-readonly-mode.md
    var mysql: MySQLConfig
    var ssh: SSHConfig?
    var createdAt: Date
    var updatedAt: Date

    /// "user@host:port/database"，走隧道时追加 "(经 ssh-host)"。用于列表副标题。
    var subtitle: String
}
```

- 密码与 Passphrase **不在** `Connection` 里，按需从 `KeychainStore` 取（见 `02-persistence.md` §3）
- 序列化格式见 `02-persistence.md` §2

## 2. 会话与全局管理

```swift
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [ConnectionSession] = []
    @Published var activeSessionID: UUID?

    var active: ConnectionSession? { sessions.first { $0.id == activeSessionID } }
    let maxConcurrentSessions = 8

    func open(_ connection: Connection) async throws -> ConnectionSession
    func switchTo(_ id: UUID)
    func disconnect(_ id: UUID) async
    func disconnectAll() async
}

@MainActor
final class ConnectionSession: ObservableObject, Identifiable {
    let id: UUID                       // == connection.id
    let connection: Connection
    @Published private(set) var state: State
    @Published private(set) var serverInfo: ServerInfo?
    @Published private(set) var databases: [String] = []
    @Published var selectedDatabase: String?

    private(set) var mysql: MySQLSession?
    private var tunnel: SSHTunnel?
    private(set) var meta: MetaRepository
    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published var activeTabID: UUID?

    enum State: Equatable {
        case disconnected
        case connecting(step: ConnectStep)
        case connected
        case failed(ConnectFailure)
    }

    enum ConnectStep: String { case sshTunnel, mysql, serverInfo }

    struct ServerInfo: Equatable {
        let version: String            // SELECT VERSION()
        let charset: String            // @@character_set_client
        let collation: String          // @@collation_connection
        let sqlMode: String            // @@sql_mode
    }

    struct ConnectFailure: Equatable {
        let step: ConnectStep
        let message: String            // 原始错误，不翻译
        let errorCode: UInt32?
        let sqlState: String?
        let sshStderr: String?         // SSH 失败时的原始输出
    }
}
```

规则：

- `SessionManager` 是唯一持有连接的地方
- **切换连接不关闭会话**（需求 §6）；只有显式断开或空闲回收才关闭
- 每个 session 一个 `MetaRepository`（元数据缓存不能跨连接共享）
- 连接上限 8，超出时 `open` 抛错，UI 提示先断开

## 3. 连接流程

```swift
func connect() async {
    state = .connecting(step: .sshTunnel)
    let endpoint: EndPoint
    if let ssh = connection.ssh, ssh.enabled {
        do {
            let localPort = try await ensureTunnel(ssh, remoteHost: connection.mysql.host,
                                                   remotePort: connection.mysql.port)
            endpoint = .tunnel(localPort: localPort)
        } catch {
            state = .failed(.init(step: .sshTunnel, message: ..., sshStderr: ...))
            return
        }
    } else {
        endpoint = .direct(host: connection.mysql.host, port: connection.mysql.port)
    }

    state = .connecting(step: .mysql)
    let password = try? keychain.get(.mysqlPassword, connection.id)
    let session = MySQLSession(config: connection.mysql, password: password, endPoint: endpoint)
    do { try await session.open() } catch { state = .failed(...); return }
    mysql = session

    state = .connecting(step: .serverInfo)
    let info = try await loadServerInfo(session)     // 见 §4
    serverInfo = info

    databases = try await loadDatabases(session)     // SHOW DATABASES，按偏好过滤系统库
    selectedDatabase = connection.mysql.database.flatMap { databases.contains($0) ? $0 : nil }
        ?? databases.first

    state = .connected
}
```

要点：

1. **隧道失败与 MySQL 失败必须是不同的错误类型**，UI 文案不能都是「连接失败」。`ConnectFailure.step` 用于区分。
2. SSH 失败要带上 `stderr` 的最后 4 KB，这是排查的唯一线索。
3. 数据库名不存在时**不报连接失败**——连接本身是成功的，只是默认库不可用；在界面上提示「连接配置里的数据库 xxx 不存在」。

### 3.1 测试连接

与 `connect()` 走同一条代码路径，但：

- 完成后立即关闭（`mysql.close()`、`tunnel.stop()`），不写入 `SessionManager`
- 不写入查询历史
- Console Log 里标为 `[meta]`
- 提供一个 `AsyncStream<ConnectStepResult>` 让 UI 分步展示

## 4. 服务器信息

```sql
SELECT VERSION(),
       @@character_set_client,
       @@collation_connection,
       @@sql_mode;
```

一次查询拿全，避免多次往返。

`SHOW DATABASES` 的结果按偏好过滤掉 `information_schema` / `performance_schema` / `mysql` / `sys`。过滤在客户端做（不拼 `WHERE`，因为 `SHOW` 不支持），但保留一份未过滤的列表以备将来使用。

## 5. 空闲回收

```swift
// 每 60 秒跑一次
for session in sessions where session.state == .connected {
    let idleInterval = connection.mysql.keepAliveInterval
    if Date.now.timeIntervalSince(session.lastUsedAt) > 300,
       session.tabs.isEmpty {
        await session.disconnect()
        session.state = .disconnected
    }
}
```

- `lastUsedAt` 在每次查询、每次切换标签时更新
- 有标签的会话不回收（避免用户切回来发现被断开了）
- 回收只断开，不删除会话对象与标签；状态为 `.disconnected`，界面显示遮罩与「重新连接」

## 6. 连接失效与重连

`MySQLSession` 检测到连接失效（心跳失败或错误码 `2006` / `2013`）时：

1. 标记自身为 `invalid`
2. 通过回调通知 `ConnectionSession`
3. `ConnectionSession` 把 `state` 置为 `.failed`，但**不自动重连**
4. 界面显示红色状态与「重新连接」按钮
5. 用户点重连时：
   - 若用了隧道且隧道也死了 → 重建隧道
   - 重建 `MySQLSession`（旧的先 `close`）
   - 成功后刷新对象树与当前标签的数据页
   - 标签里的 `PendingChangeStore` **不清空**（用户的修改还在）

这是刻意的选择（需求 §5 与 `13-open-questions.md` L8）：不自动重连，避免在用户不知情时反复尝试。

## 7. 退出与清理

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // 1. 找出所有有未提交改动的标签
    // 2. 依次弹确认（提交 / 放弃 / 取消）
    // 3. 全部处理完后：reply(toApplicationShouldTerminate: true)
    //    - 关闭所有 MySQLSession
    //    - 停止所有 SSHTunnel（同步等待进程退出，最多 2 秒，然后 SIGKILL）
    //    - flush Console Log 落盘（若开启）
    return .terminateLater
}
```

**退出时必须确保没有残留的 ssh 进程**，这是冒烟脚本会检查的一项。

## 8. 会话恢复

需求见 [`specs/11-preferences.md`](../../specs/11-preferences.md) §1。

```jsonc
// ~/Library/Application Support/TableLite/session.json
{
  "version": 1,
  "activeConnectionId": "8F2A1C34-…",
  "sessions": [
    {
      "connectionId": "8F2A1C34-…",
      "selectedDatabase": "app_dev",
      "activeTabIndex": 0,
      "tabs": [
        { "kind": "tableData", "schema": "app_dev", "table": "users",
          "page": { "pageSize": 300, "offset": 0 },
          "sort": [{ "column": "id", "ascending": true }],
          "filter": { "conditions": [], "conjunction": "and" },
          "hiddenColumns": [] },
        { "kind": "query", "draftId": "A1B2…", "title": "查询 1" }
      ]
    }
  ]
}
```

恢复策略：

- 启动时读取该文件，恢复出**连接会话的骨架与标签**
- **不自动连接**。每个会话显示为「点击重连」，用户可以逐个连，也可以点「恢复全部」
- 查询标签的内容从 `drafts/<draftId>.sql` 读取
- 该行为可在偏好中关闭；关闭时不写该文件，启动即显示连接列表
- 写文件用「临时文件 + 原子替换」，与 `02-persistence.md` §2.1 一致

## 9. 查询标签的草稿存储

- 每个查询标签有一个 `draftId`（UUID）
- 编辑内容防抖 1 秒写入 `~/Library/Application Support/TableLite/drafts/<draftId>.sql`
- 标签关闭时删除对应草稿文件（已另存为磁盘文件的除外）
- 启动时清理孤儿草稿文件（超过 30 天且未被 `session.json` 引用的）

## 10. 状态栏数据的来源

连接区域状态栏显示 `● 名称 · 库 · 服务器版本 · 字符集 · 只读`：

| 片段 | 来源 |
| --- | --- |
| 状态点 | `ConnectionSession.state` |
| 名称 | `Connection.name` |
| 库 | `selectedDatabase` |
| 服务器版本 | `serverInfo.version`（首次连接时取，不重复查询） |
| 字符集 | `serverInfo.charset` |
| 只读 | `Connection.readOnly` |
