# 01 · 整体架构

## 1. 分层

```
┌──────────────────────────────────────────────────────────────┐
│  UI 层（SwiftUI + AppKit）                                    │
│  WorkspaceShell / Connections / DataGrid / QueryEditor /      │
│  Filter / QuickLook / ImportExport / SchemaViewer             │
└───────────────┬──────────────────────────────────────────────┘
                │  @MainActor 的 ObservableObject / ViewModel
┌───────────────▼──────────────────────────────────────────────┐
│  应用状态层                                                   │
│  SessionManager（持有多个 ConnectionSession）                  │
│  ConnectionSession = { Connection, MySQLSession, SSHTunnel? } │
│  每个 Tab 的 ViewModel 持有 PendingChangeStore / FilterState   │
└───────────────┬──────────────────────────────────────────────┘
                │  Swift async / await
┌───────────────▼──────────────────────────────────────────────┐
│  数据访问层                                                   │
│  MySQLSession (actor)  ──►  CMySQLClient (C shim)             │
│  MetaRepository         ──►  information_schema 查询          │
│  SQLLexer / StatementSplitter / SQLValueLiteral               │
│  SSHTunnel                                                    │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│  系统层                                                       │
│  libmysqlclient.dylib（Homebrew mysql-client）                │
│  /usr/bin/ssh        libsqlite3        Security.framework     │
│  (Keychain)                                                   │
└──────────────────────────────────────────────────────────────┘
```

**依赖方向严格向下**。UI 层不得直接 import `CMySQLClient`；所有数据库访问都必须经过 `MySQLSession` / `MetaRepository`。

## 2. 模块与目录

```
TableLite/
├── project.yml                     # XcodeGen 声明
├── Makefile                        # gen / build / run / test / deps / clean
├── scripts/
│   └── check-deps.sh               # 校验 brew 依赖与头文件/库路径
├── specs/                          # 需求设计（用户视角）
├── docs/
│   ├── README.md
│   ├── roadmap.md                  # 实现路线图
│   └── tech-designs/               # 技术设计（本目录）
├── Sources/
│   ├── CMySQLClient/               # C target（clang）
│   │   ├── include/CMySQLClient.h
│   │   ├── CMySQLClient.c
│   │   └── module.modulemap
│   └── TableLite/                  # App target（Swift）
│       ├── App/
│       │   ├── TableLiteApp.swift          # @main
│       │   ├── AppDelegate.swift           # 退出清理、菜单
│       │   └── AppCommands.swift           # 菜单栏与快捷键
│       ├── Core/
│       │   ├── MySQL/
│       │   │   ├── MySQLSession.swift      # actor，连接的唯一入口
│       │   │   ├── MySQLResult.swift       # 结果集 / 列元数据 / 行
│       │   │   ├── MySQLValue.swift        # 值模型与类型映射
│       │   │   ├── MySQLConfig.swift       # 连接参数
│       │   │   └── MySQLError.swift        # 错误模型
│       │   ├── SSH/
│       │   │   └── SSHTunnel.swift
│       │   ├── Model/
│       │   │   ├── Connection.swift
│       │   │   ├── DatabaseObject.swift
│       │   │   ├── TableSchema.swift
│       │   │   ├── PendingChange.swift
│       │   │   ├── FilterCondition.swift
│       │   │   └── QueryHistoryEntry.swift
│       │   ├── Store/
│       │   │   ├── ConnectionStore.swift
│       │   │   ├── KeychainStore.swift
│       │   │   ├── HistoryStore.swift      # libsqlite3
│       │   │   └── PreferencesStore.swift  # UserDefaults
│       │   ├── SQL/
│       │   │   ├── SQLLexer.swift          # 高亮 + 语句分类
│       │   │   ├── StatementSplitter.swift
│       │   │   ├── SQLValueLiteral.swift   # 值 → SQL 字面量（转义）
│       │   │   └── SQLBuilder.swift        # SELECT/INSERT/UPDATE/DELETE 生成
│       │   └── Meta/
│       │       └── MetaRepository.swift    # information_schema 查询与缓存
│       ├── Features/
│       │   ├── Connections/
│       │   │   ├── ConnectionListView.swift
│       │   │   └── ConnectionEditView.swift
│       │   ├── Workspace/
│       │   │   ├── WorkspaceRootView.swift
│       │   │   ├── SessionManager.swift
│       │   │   ├── ConnectionSession.swift
│       │   │   ├── ConnectionSwitcher.swift
│       │   │   ├── ObjectSidebarView.swift
│       │   │   ├── TabBarView.swift
│       │   │   └── StatusBarView.swift
│       │   ├── DataGrid/
│       │   │   ├── DataGridView.swift          # SwiftUI 入口
│       │   │   ├── DataGridTableView.swift     # NSViewRepresentable
│       │   │   ├── DataGridCoordinator.swift   # 数据源 / 委托 / 编辑
│       │   │   ├── DataGridCellView.swift
│       │   │   └── PaginationBarView.swift
│       │   ├── Filter/
│       │   │   ├── RowFilterPanel.swift
│       │   │   └── ColumnFilterPanel.swift
│       │   ├── QueryEditor/
│       │   │   ├── QueryEditorView.swift
│       │   │   ├── SQLEditorTextView.swift     # NSTextView 封装
│       │   │   ├── ResultTabStrip.swift
│       │   │   ├── QueryHistoryView.swift
│       │   │   └── ConsoleLogView.swift
│       │   ├── QuickLook/
│       │   │   └── QuickLookPanel.swift
│       │   └── ImportExport/
│       │       ├── ExportSheet.swift
│       │       └── CSVImportWizard.swift
│       └── Resources/
│           ├── Info.plist
│           └── TableLite.entitlements
└── Tests/
    └── TableLiteTests/
        ├── StatementSplitterTests.swift
        ├── SQLLexerTests.swift
        ├── SQLValueLiteralTests.swift
        ├── MySQLValueMappingTests.swift
        ├── CSVCodecTests.swift
        └── SSHCommandBuilderTests.swift
```

## 3. 并发模型

这是本项目最容易出错的地方，规则必须严格遵守。

### 3.1 规则

1. **`CMySQLClient` 的连接句柄不是线程安全的。**
   每个 `MySQLSession` 持有一条**专用串行队列**（`DispatchQueue(label: "tablelite.mysql.<uuid>")`）。
   对该 session 的**所有** libmysqlclient 调用（query / ping / kill / close）都必须在该队列上执行。禁止在不同的队列上并发调用。

2. **`MySQLSession` 是一个 `actor`**，对外暴露 `async` 方法。
   actor 内部通过 `withCheckedThrowingContinuation` 把工作投递到上述串行队列。

3. **`mysql_kill` 是唯一允许跨队列调用的例外**，它只读取预先缓存的 `thread_id` 并通过一个独立的控制连接发送 `KILL QUERY <id>`，不触碰原连接句柄。

4. **C 回调运行在串行队列上**，回调内只做「把数据写进本地缓冲/通过 continuation 回传」，**不得**回调进 UI。

5. **UI 状态一律在 `@MainActor` 上**。`SessionManager`、各 ViewModel、`PendingChangeStore` 均为 `@MainActor`。

6. 使用 Swift 6 严格并发检查（`SWIFT_STRICT_CONCURRENCY = complete`），不允许 `@unchecked Sendable`（C shim 的 opaque 指针除外，用 `@unchecked Sendable` 的 `final class` 包装并注释理由）。

### 3.2 取消

`Task` 取消 → `MySQLSession` 的 `query` 方法监听 `Task.isCancelled`，一旦取消就调用 `killQuery()`（发 `KILL QUERY`），并丢弃后续到达的行。

### 3.3 并发上限

同一连接**串行**执行查询（MySQL 协议本身也不允许连接上并发执行）。不同连接之间完全并行。

## 4. 关键数据流

### 4.1 打开一张表

```
用户点对象树里的表
  → SessionManager.openTable(schema, table)
  → 新建 TableTab（含 PendingChangeStore / FilterState / GridState）
  → MetaRepository.columns(schema, table)   [缓存命中则跳过]
  → 判定可编辑性：有 PK 或 UNIQUE NOT NULL → editable
  → MySQLSession.query(SELECT * FROM `s`.`t` ORDER BY ... LIMIT 300 OFFSET 0)
  → DataGridViewModel.rows = …
  → DataGridTableView.reloadData()
```

### 4.2 编辑并提交

```
双击单元格 → 内联编辑器
  → 提交编辑：DataGridViewModel.applyEdit(rowID, column, newValue)
      · 若改的是主键列，记 oldPK / newPK
      · 写入 PendingChangeStore
      · 标脏该行（重绘，不重新查询）
  → ⌘⇧P → PendingChangeStore.pendingSQL() → Preview 面板
  → ⌘S   → CommitCoordinator
      · readonly 连接 → 拒绝
      · START TRANSACTION
      · 逐条执行 pending SQL（prepared statement + bind）
      · 全部成功 → COMMIT；任一失败 → ROLLBACK + 展示失败语句与错误
      · 成功后清空 store，刷新当前页
  → ⌘⇧Delete → 清空 store + 重绘
```

### 4.3 执行 SQL

```
⌘↩ / ⌘⇧↩
  → 若 readonly 连接：用 SQLLexer 做语句分类，命中写操作则拒绝
  → StatementSplitter.split(text) → [Statement(range, sql)]
  → 选中要执行的语句集合
  → MySQLSession.executeScript(sql) → AsyncStream<StatementResult>
      · C shim 走 CLIENT_MULTI_STATEMENTS，循环 mysql_next_result
      · 每个结果集回调 on_result_set / on_row / on_affected
  → 结果区顶部生成 N 个标签
  → 写入 HistoryStore + ConsoleLog
```

## 5. 错误传播

- C shim 只返回错误码 + 文本缓冲，不抛异常。
- Swift 侧统一映射为 `MySQLError`：

```swift
enum MySQLError: LocalizedError {
    case notConnected
    case sshTunnelFailed(reason: String)
    case connectFailed(code: UInt32, sqlState: String?, message: String)
    case server(code: UInt32, sqlState: String?, message: String)   // 执行期
    case timeout(seconds: Int, killed: Bool)
    case cancelled
    case protocolViolation(String)
    case unsupported(String)
}
```

- UI 展示规则：`code + sqlState + message` 原样展示（不要翻译服务器原文），另加一行中文解释。
- 错误不吞掉：所有 `catch` 必须至少有 `ConsoleLog` 记录。

## 6. 依赖与外部约束

| 依赖 | 来源 | 用途 |
| --- | --- | --- |
| libmysqlclient | Homebrew `mysql-client`（keg-only） | MySQL 协议 |
| OpenSSL / zstd | Homebrew（`mysql-client` 的依赖） | libmysqlclient 的传递依赖 |
| libsqlite3 | macOS 系统自带 | 查询历史 / Console Log |
| Security.framework | 系统 | Keychain |
| AppKit / SwiftUI | 系统 | UI |
| /usr/bin/ssh | 系统 | SSH 隧道 |

不引入任何第三方 Swift Package（保持零 SPM 依赖）。如果将来需要，必须先在 `13-open-questions.md` 记录理由。

## 7. 沙箱与权限

- **不开启 App Sandbox**（`com.apple.security.app-sandbox = false`）。
  理由：需要读取 `~/.ssh/config` 与私钥、需要以用户身份启动 `ssh` 子进程、需要连接任意 TCP 主机。
- 仍然保留 hardened runtime 关闭状态（不签名本地构建）。
- 只申请 `com.apple.security.network.client`（即使不开沙箱也写上，便于将来切换）。
