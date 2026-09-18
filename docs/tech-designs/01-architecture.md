# 01 · 整体架构

## 1. 分层与依赖方向

自上而下四层：

1. **UI 层** —— SwiftUI 为主；数据网格与 SQL 编辑器下沉 AppKit。
2. **应用状态层** —— `SessionManager` 持有多个 `ConnectionSession`；每个标签的 ViewModel 持有自己的暂存区与过滤器状态。
3. **数据访问层** —— `MySQLSession`（actor）、`MetaRepository`、SSH 隧道、SQL 纯逻辑工具。
4. **系统层** —— libmysqlclient、`/usr/bin/ssh`、libsqlite3、Security.framework。

**硬约束：依赖方向严格向下。** UI 层不得直接 `import CMySQLClient`；所有数据库访问必须经过 `MySQLSession` / `MetaRepository`。

## 2. 模块划分

| 模块 | 职责 |
| --- | --- |
| `Core/MySQL` | 连接与查询，对外唯一入口（actor） |
| `Core/SSH` | SSH 隧道 |
| `Core/Model` | 连接、表结构、暂存变更、过滤条件等模型 |
| `Core/Store` | 连接配置、Keychain、查询历史、偏好 |
| `Core/SQL` | 词法扫描、语句拆分、字面量生成、SQL 生成（纯函数，可单测） |
| `Core/Meta` | `information_schema` 查询与缓存 |
| `Features/*` | 各界面模块 |
| `Sources/CMySQLClient` | C shim，只负责隔离 C 宏、内存与线程模型 |
| `Tests/TableLiteTests` | 纯逻辑单测 |

具体文件清单以代码为准，不在文档里维护。

## 3. 并发模型

本项目最容易出错的地方，以下为硬约束。

1. **连接句柄不是线程安全的。** 每个 `MySQLSession` 持有一条专用串行队列；对该 session 的所有 libmysqlclient 调用（query / ping / kill / close）都必须在该队列上执行，禁止跨队列并发调用。
2. **`MySQLSession` 是 actor**，对外只暴露 `async` 方法，内部把工作投递到上述串行队列。
3. **`mysql_kill` 是唯一允许跨队列调用的例外**：只读取预先缓存的 `thread_id`，经独立控制连接发 `KILL QUERY`，不触碰原连接句柄。
4. **C 回调只做数据复制**，不得回灌 UI。
5. **UI 状态一律 `@MainActor`**；`SessionManager`、各 ViewModel、暂存区都是 `@MainActor`。
6. **Swift 6 严格并发**（`SWIFT_STRICT_CONCURRENCY = complete`）。不允许 `@unchecked Sendable`，唯一例外是包装 C 指针的 `final class`，必须写明理由。

### 3.1 取消

`Task` 取消后调用 `KILL QUERY`，并丢弃取消后到达的行。

### 3.2 并发上限

同一连接上的查询**串行**执行（MySQL 协议本身也不允许连接上并发执行）；不同连接之间完全并行。

## 4. 错误传播

- C shim 不抛异常，只返回错误码 + 文本缓冲。
- Swift 侧统一映射为 `MySQLError`；UI **原样展示** `code + sqlState + message`（不翻译服务器原文），另附一行中文解释。
- **禁止吞错误**：所有 `catch` 至少要写一条 Console Log。

## 5. 沙箱与签名

- **不开启 App Sandbox**，理由：需要读 `~/.ssh/config` 与私钥、以用户身份启动 `ssh` 子进程、连接任意 TCP 主机。
- 不签名、不公证，关闭 hardened runtime。
- 仍申请 `com.apple.security.network.client`，便于将来切换。

## 6. 依赖与外部约束

| 依赖 | 来源 | 用途 |
| --- | --- | --- |
| libmysqlclient | Homebrew `mysql-client` | MySQL 协议 |
| libsqlite3 | macOS 系统 | 查询历史 / Console Log |
| Security.framework | 系统 | Keychain |
| AppKit / SwiftUI | 系统 | UI |
| /usr/bin/ssh | 系统 | SSH 隧道 |

**零第三方 Swift Package 依赖。** 将来要引入必须先在 `13-open-questions.md` 登记理由（T10）。
