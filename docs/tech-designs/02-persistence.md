# 02 · 配置与持久化

## 1. 存储位置总览

| 数据 | 位置 | 格式 | 含凭据 |
| --- | --- | --- | --- |
| 连接元数据 | `~/Library/Application Support/TableLite/connections.json` | JSON | 否 |
| 数据库密码 / SSH 密码 / SSH 私钥口令 | `…/credentials.json` | JSON（明文，`0600`） | 是 |
| 查询历史 | `…/history.sqlite3` | SQLite | 否 |
| Console Log | 内存环形缓冲，可选落盘 | 文本 | 否 |
| 偏好设置 | `UserDefaults`（`com.graycarl.tablelite`） | plist | 否 |
| 窗口框架 / 标签现场 | `UserDefaults`（窗口框架）+ `session.json`（标签现场） | JSON | 否 |
| 导入 / 导出 | 用户选择路径 | CSV | 否 |

**约束**：目录用 `FileManager` 解析，不硬编码路径。

## 2. 连接元数据

- 存 `connections.json`，带 `schemaVersion` 字段（版本与迁移策略见 §9）。
- 只读标记 `readOnly` 存在这里，不进凭据文件。
- **禁止**把 `password` / `passphrase` 写进 `connections.json`；反序列化时若发现该字段直接丢弃并记录警告。

### 2.1 写入策略

- 写文件用「临时文件 + 原子替换」。
- 文件权限 `0600`，目录 `0700`。

## 3. 凭据存储（决策记录）

**决策：密码 / 口令存在单独的文件里，不用 Keychain。**

- 位置 `~/Library/Application Support/TableLite/credentials.json`，文件 `0600`、目录 `0700`，带
  `schemaVersion`，写入走「临时文件 + 原子替换」（同 §2.1、§9）。
- 按 `connection.id` 分组，每组三个值：数据库密码、SSH 密码、SSH 私钥口令；空串等价于删除（与
  「清空密码框」一致）。
- **明文存放，不加密**：本机唯一能可靠保管密钥的地方就是 Keychain，绕不开 §3.1，代价与自用工具版的
  `~/.my.cnf` 相当。安全边界登记在 `13-open-questions.md` S42。
- 删除连接时**必须**连带删除对应的三个值。
- 「测试连接」成功后才询问是否保存密码；失败不保存。
- 连接表单的密码框默认从这里回填；提供「忘记 / 清除密码」。
- 旧的 Keychain 条目不再读写，**不自动迁移、也不自动清理**（`13-open-questions.md` L45）。

### 3.1 为什么不用 Keychain（2026-09-29 重定案）

登录（file-based）钥匙串对「始终允许」有两道门，都按同一个签名身份判定：

1. **ACL 受信任应用**（`CodeSignatureAclSubject[requirement:…]`）：自签名证书能把它固定成
   `identifier "…" and certificate leaf = H"…"`，跨构建稳定。
2. **XARA partition**（`___PARTITION___` ACL 条目）：一串**字面量**，securityd 只做字符串包含判断。
   自签名证书没有 TeamID（`codesign -dvvv` 里 `TeamIdentifier=not set`），App 的 partition 只能是
   `cdhash:<二进制哈希>` —— 改一行代码就变，于是**每次重新构建都要再点一次「始终允许」**。

实测结论（本机 macOS 27，与 `securityd/src/acls.cpp` 的 `createClientPartitionID()` 一致）：客户端
partition 只有 `unsigned:` / `apple:` / `apple-tool:` / `teamid:<TEAM>` / `cdhash:<H>` 五种，**没有**
`req:` 这类写法；`security add-generic-password -A`（allow-any-app）也拦不住第二道门；`SecItemAdd`
自带 `SecAccess` 会被 securityd 用创建者的 partition 覆盖；改已有条目的 partition 列表必须提供登录
钥匙串密码。所以只有真 Apple 签名（`teamid:`）或 data protection keychain（需要 entitlement +
描述文件；自签名 + 手写 entitlement 被 AMFI `Killed: 9`）能解。详见 `13-open-questions.md` T13、
`12-build-and-deps.md` §3.4。

## 4. 查询历史

- 存在 `history.sqlite3`，用系统 `libsqlite3`，开启 WAL。
- **只记录来自 SQL 编辑器的语句**；对象树刷新、元数据查询、网格数据查询不写历史（但写 Console Log）。
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
