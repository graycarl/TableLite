# 02 · 配置与持久化

## 1. 存储位置总览

| 数据 | 位置 | 格式 | 是否含密文 |
| --- | --- | --- | --- |
| 连接元数据 | `~/Library/Application Support/TableLite/connections.json` | JSON | 否（不含任何口令） |
| 数据库密码 | 系统 Keychain | `kSecClassGenericPassword` | 是 |
| SSH 密码 / 私钥 Passphrase | 系统 Keychain | 同上 | 是 |
| 查询历史 | `~/Library/Application Support/TableLite/history.sqlite3` | SQLite | 否 |
| Console Log | 内存环形缓冲；可选落盘 `console.log`（默认关） | 文本 | 否 |
| 偏好设置 | `UserDefaults`（`com.graycarl.tablelite`） | plist | 否 |
| 窗口 / Tab 状态 | `UserDefaults`（`NSWindow` frame autosave + 自维护 JSON） | JSON | 否 |
| 导出 / 导入 | 用户选择路径 | CSV | 否 |

> 目录用 `FileManager.default.url(for: .applicationSupportDirectory, ...)` 解析，不要硬编码路径。

## 2. 连接元数据（connections.json）

```jsonc
{
  "version": 1,
  "connections": [
    {
      "id": "8F2A1C34-…",                  // UUID，稳定主键
      "name": "本地开发",
      "colorHex": "#2E7D32",               // 可为 null
      "readOnly": false,
      "createdAt": "2025-01-01T00:00:00Z",
      "updatedAt": "2025-01-01T00:00:00Z",

      "mysql": {
        "host": "127.0.0.1",
        "port": 3306,
        "user": "root",
        "database": "app_dev",             // 可为 null（不指定默认库）
        "charset": "utf8mb4",
        "collation": null,
        "useSSL": true,
        "sslSkipVerify": false,
        "connectTimeoutSeconds": 10,
        "queryTimeoutSeconds": 300,
        "keepAlive": true,
        "keepAliveIntervalSeconds": 30
      },

      "ssh": null                          // 或见下
    }
  ]
}
```

`ssh` 非空时的结构：

```jsonc
{
  "enabled": true,
  "host": "bastion.example.com",
  "port": 22,
  "user": "deploy",
  "authMethod": "password" | "privateKey" | "agentOrConfig",
  "privateKeyPath": "~/.ssh/id_ed25519",   // authMethod == privateKey 时
  "useConfigHostAlias": true,              // true 时 host 可写成 ~/.ssh/config 里的别名
  "jumpHost": null                         // 形如 "user@proxy:22"，透传给 ssh -J
}
```

**禁止**把 `password` / `passphrase` 写进 JSON。反序列化时若发现字段直接丢弃并记录警告。

### 2.1 写入策略

- 写文件用「写临时文件 + `FileManager.replaceItemAt`」保证原子性
- 文件权限 `0600`，目录 `0700`
- 只读连接的 `readOnly` 保存在这里（不是 Keychain）

## 3. Keychain

### 3.1 键约定

| 用途 | `kSecAttrService` | `kSecAttrAccount` |
| --- | --- | --- |
| 数据库密码 | `com.graycarl.tablelite.mysql` | `<connection.id>` |
| SSH 密码 | `com.graycarl.tablelite.ssh.password` | `<connection.id>` |
| SSH 私钥 Passphrase | `com.graycarl.tablelite.ssh.passphrase` | `<connection.id>` |

### 3.2 API

```swift
protocol KeychainStoring: Sendable {
    func set(_ secret: String, service: String, account: String) throws
    func get(service: String, account: String) throws -> String?
    func delete(service: String, account: String) throws
}
```

- `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`（自用工具无需每次解锁）
- 写入前先 `delete` 再 `add`（Keychain 不支持直接 update 全部属性）
- 删除连接时必须连带删除三个 Keychain 条目
- 「测试连接」成功后询问是否保存密码；失败不保存

### 3.3 输入体验

- 连接表单的密码框默认从 Keychain 回填（显示为 `••••••`）
- 提供一个「忘记/清除密码」按钮
- 首次连接若 Keychain 无密码 → 弹密码输入（不落盘除非用户勾选「保存密码」）

## 4. 查询历史（history.sqlite3）

```sql
CREATE TABLE IF NOT EXISTS query_history (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  connection_id TEXT    NOT NULL,
  database_name TEXT,
  sql           TEXT    NOT NULL,
  started_at    REAL    NOT NULL,   -- Unix epoch 秒
  duration_ms   INTEGER NOT NULL,
  row_count     INTEGER,            -- NULL 表示非查询语句
  affected_rows INTEGER,
  status        TEXT    NOT NULL,   -- 'ok' | 'error' | 'cancelled' | 'timeout'
  error_code    INTEGER,
  error_message TEXT
);
CREATE INDEX IF NOT EXISTS idx_history_conn_time ON query_history(connection_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_history_sql ON query_history(sql);
```

- 只记录来自 **SQL 编辑器** 的语句；对象树刷新、`information_schema` 元数据查询、网格分页查询**不**写入历史（但会写 Console Log）
- 通过 `consoleLogOnly` 参数区分
- 保留策略：默认保留最近 5000 条，超出时按 `started_at` 删除
- 「清空历史」= `DELETE FROM query_history WHERE connection_id = ?`
- 直接使用系统 `libsqlite3`，接口封装在 `HistoryStore`（同步 API，通过 actor 串行化）
- 打开数据库时设 `PRAGMA journal_mode = WAL`

## 5. Console Log

- 内容：**所有**下发到服务器的语句（含元数据查询与网格分页查询），带标签 `[meta]` / `[data]` / `[script]`
- 记录字段：时间、连接 id、数据库、SQL、耗时、行数/影响行数、成功/失败
- 内存环形缓冲，容量 5000 条（需求见 [`specs/06-query-editor.md`](../../specs/06-query-editor.md) §6）
- 默认**不落盘**；偏好里可开启写入 `console.log`（按天轮转，保留 7 天）
- UI 过滤：`全部 / 仅数据语句 / 仅元数据语句`
- 支持一键复制全部 / 清空

## 6. 偏好设置（UserDefaults）

全部键与默认值的清单见实现时的 `PreferencesKeys` 枚举；需求侧的选项说明见 [`specs/11-preferences.md`](../../specs/11-preferences.md)。

约定：

- 键名格式 `<域>.<项>`，例如 `grid.pageSize`、`editor.fontSize`、`csv.delimiter`
- 所有键在 `PreferencesStore` 里集中声明并给出默认值，禁止在视图里直接读写 `UserDefaults`
- 敏感信息（密码、口令）**禁止**放进 `UserDefaults`
- 与机器或连接绑定的状态（列宽、过滤器）用连接 id / `schema.table` 作为键的一部分

## 7. 窗口与工作区状态

窗口 frame 用 `NSWindow.setFrameAutosaveName("MainWindow")`。会话与标签的恢复格式见 [`05-session-management.md`](05-session-management.md) §8。

单窗口应用：`WindowGroup` 不提供「新建窗口」，`⌘N` 绑定的是「新建连接」。

## 8. 日志

- 使用 `os.Logger`，subsystem 为 `com.graycarl.tablelite`
- 分类：`mysql` / `ssh` / `ui` / `store`
- 连接字符串、SQL 全文、密码**一律不打日志**；SQL 只在 `ConsoleLog` 里出现（那是用户可见的功能）
- `#if DEBUG` 下允许打印到控制台
