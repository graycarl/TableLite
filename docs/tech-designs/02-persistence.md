# 02 · 配置与持久化

## 1. 存储位置总览

| 数据 | 位置 | 格式 | 含密文 |
| --- | --- | --- | --- |
| 连接元数据 | `~/Library/Application Support/TableLite/connections.json` | JSON | 否 |
| 数据库密码 | 系统 Keychain | generic password | 是 |
| SSH 密码 / 私钥 Passphrase | 系统 Keychain | generic password | 是 |
| 查询历史 | `…/history.sqlite3` | SQLite | 否 |
| Console Log | 内存环形缓冲，可选落盘 | 文本 | 否 |
| 偏好设置 | `UserDefaults`（`com.graycarl.tablelite`） | plist | 否 |
| 窗口框架 / 标签现场 | `UserDefaults`（窗口框架）+ `session.json`（标签现场） | JSON | 否 |
| 导入 / 导出 | 用户选择路径 | CSV | 否 |

**约束**：目录用 `FileManager` 解析，不硬编码路径。

## 2. 连接元数据

- 存 `connections.json`，带 `schemaVersion` 字段（版本与迁移策略见 §9）。
- 只读标记 `readOnly` 存在这里，不进 Keychain。
- **禁止**把 `password` / `passphrase` 写进 JSON；反序列化时若发现该字段直接丢弃并记录警告。

### 2.1 写入策略

- 写文件用「临时文件 + 原子替换」。
- 文件权限 `0600`，目录 `0700`。

## 3. Keychain

- service 前缀区分用途（数据库密码 / SSH 密码 / SSH Passphrase）；account 固定为 `connection.id`。
- 可访问级别 `kSecAttrAccessibleAfterFirstUnlock`（自用工具，不需要每次解锁）。
- 写入前先 `delete` 再 `add`（Keychain 不支持直接修改全部属性）。
- 删除连接时**必须**连带删除对应的三个条目。
- 「测试连接」成功后才询问是否保存密码；失败不保存。
- 连接表单的密码框默认从 Keychain 回填；提供「忘记 / 清除密码」。

## 4. 查询历史

- 存在 `history.sqlite3`，用系统 `libsqlite3`，开启 WAL。
- **只记录来自 SQL 编辑器的语句**；对象树刷新、元数据查询、网格分页查询不写历史（但写 Console Log）。
- 保留策略：默认保留最近 5000 条，超出按时间删除。
- 「清空历史」按连接删除。

## 5. Console Log

- 记录**所有**下发到服务器的语句，带 `[data]` / `[meta]` 标签（`[data]` 用户发起、`[meta]` 客户端自动发出）。
- 内存环形缓冲，容量 5000（需求见 `specs/06-query-editor.md` §6）。
- 默认不落盘；偏好可开启写文件，按天轮转、保留 7 天（需求见 `specs/11-preferences.md` §7）。
- UI 支持按标签过滤、复制全部、清空。

## 6. 偏好设置

- 键名格式 `<域>.<项>`（如 `grid.pageSize`）。
- **约束**：所有键在 `PreferencesStore` 中集中声明并给出默认值，禁止在视图里直接读写 `UserDefaults`；敏感信息禁止进 `UserDefaults`。
- 与机器 / 连接绑定的状态（列宽、过滤器）用连接 id / `schema.table` 作为键的一部分。

## 7. 窗口与工作区状态

- 窗口 frame 用 `NSWindow.setFrameAutosaveName`。
- 单窗口应用：`WindowGroup` 不提供「新建窗口」，`⌘N` 绑定「新建连接」。
- 会话与标签的恢复格式见 `05-session-management.md` §8。

## 8. 日志

- 用 `os.Logger`，subsystem `com.graycarl.tablelite`，分类 `mysql` / `ssh` / `ui` / `store`。
## 9. 版本与迁移（决策记录）

**只做向前兼容读取，不做迁移框架。**

- 落盘数据都带一个整数版本：JSON 用 `schemaVersion`，SQLite 用 `PRAGMA user_version`。当前都是 `1`。
- 读取时未知字段忽略、缺失字段取默认值 —— 所以「加字段」通常不用升版本。
- 只有**破坏性变更**（改语义、删字段并重新解释）才递增版本号。
- 遇到不认识的版本：把原文件备份成 `<文件名>.bak-<版本>`，然后按默认值重建，并在界面上说明
  —— 不静默丢数据，也不写迁移代码。
- 不引入版本迁移库：这点旧数据不值得为它承担迁移代码的维护面。
