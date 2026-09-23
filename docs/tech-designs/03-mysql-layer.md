# 03 · MySQL 数据访问层

依赖 Homebrew `mysql-client` 提供的 `libmysqlclient`。分两层：C shim（`CMySQLClient`）只隔离 C 宏、内存与线程模型；Swift `MySQLSession` 负责异步、类型映射与业务语义。

## 1. 设计原则

1. **不用 prepared statement。** 所有写入都生成 SQL 字面量下发。理由：
   - 用户点 Preview 就要看到**最终下发的原文**，prepared statement 会让 Preview 与实际执行不一致；
   - `mysql_real_escape_string` 会按服务器 `sql_mode`（`NO_BACKSLASH_ESCAPES`）与连接 charset 正确转义，比自己写更安全；
   - 二进制走 `0x…` 十六进制字面量，完全不经过转义路径。
2. **读多行走 text protocol**，值以「原始字节 + 列元数据」交给上层，类型解释由 Swift 侧按列类型决定；避免二进制协议的类型坑。
3. **C 与 Swift 的边界只传指针数组，不传 JSON**，避免编解码开销与转义 bug。
4. **一行数据必须在 C 回调返回前复制走**，因为 `mysql_fetch_row` 的缓冲区会被下一次调用复用。
5. **转义策略固定**：字符串走 `mysql_real_escape_string`，二进制走 `0x…` 十六进制字面量，不写自制转义函数。

## 2. C shim 的边界

- 只贴 libmysqlclient 的 C API，不含业务语义。
- 取行必须配合 `mysql_fetch_lengths` 取长度，**禁止 `strlen`**（`mysql_fetch_row` 的字节串可能含 `\0`）。
- 列元数据里的 `char *` 生命周期与结果集一致，只在本次回调内有效，上层必须立刻复制。
- 多结果集：连接时开启 `CLIENT_MULTI_STATEMENTS`，循环 `mysql_next_result` 取完一次下发产生的全部结果集（`CALL` 这类单条语句本身就可能返回多个结果集）。上层默认逐条下发语句；某条出错后是否下发下一条由上层按偏好决定（见 `10-query-editor.md` §5.4）。
- 连接建立时**必须**设置 charset（它决定 `mysql_real_escape_string` 的行为，不能省）、**禁止** `LOAD DATA LOCAL`、**不得**擅自改用户的 `sql_mode` / 会话变量、不启用库层自动重连（重连由上层显式控制）。

## 3. Swift 封装

- `MySQLSession` 是 actor，所有数据库访问都经过它。
- 查询以异步事件流返回（结果集开始 / 行 / 影响行数 / 单语句错误 / 结束），上层逐事件消费。
- **背压没有严格实现**（L1）：结果集采用有界缓冲策略，超大结果集时内存会增长。若实际使用中成为问题，改为「有界缓冲 + 阻塞式回调」。此项简化必须保持在 `13-open-questions.md` 的登记。
- `MySQLSession` **不自己跟踪当前数据库**：连接默认库由上层在切库 / 连接时用 `USE` 同步（`05-session-management.md` §11）。

## 4. 类型映射与字面量生成

### 4.1 显示与编辑

- 由列类型决定显示文本与编辑器；多数类型直接取原始字节按类型解释。
- 数字 / 十进制 / 浮点：十进制原样文本，**不做浮点转换**。
- 日期时间：按 MySQL 的文本形式显示。
- `ENUM` / `SET` 的值域来自 `COLUMN_TYPE`。
- 二进制 / BLOB 不与文本混用，显示为 hex 或大小占位。
- `TINYINT(1)` 是否显示为复选框由偏好 `grid.tinyInt1AsBool` 控制，**默认关闭**（很多项目用它存 0/1/2）。

### 4.2 字面量生成（`SQLValueLiteral`）

- `NULL` → `NULL`。
- 字符串 → 单引号 + 转义结果；连接 charset 非 utf8 系时加 introducer。
- 二进制 → `0x` + 大写 hex；空串为 `X''`。
- 数字列 → **严格正则** `^-?\d+$` 或 `^-?\d+\.\d+$` 才去引号；不允许 `1e5`、`0x1`、前导 `+`、空白。
- 任何无法确定的情况一律走字符串字面量，**永不拼接未验证的内容**。
- 必须是纯函数，单元测试覆盖单引号、双引号、反斜杠、换行、`\0`、emoji 与 `NO_BACKSLASH_ESCAPES` 场景。

### 4.3 时区（决策记录）

**客户端不做任何时区处理：日期时间值原样读、原样写。**

- 服务器发来的文本原样显示，编辑后原样写回，中间不解析、不换算、不解释。
- `TIMESTAMP` 由服务器按会话时区换算、`DATETIME` 不换算 —— 客户端不关心，也不向用户解释这件事。
- 编辑一律走 `SQLValueLiteral` 的字符串路径，**禁止**把本地时间转成 UTC 再写。
- 日期选择器生成的文本就是控件里示意的墙钟时间，不做偏移。

刻意简化（S27）：时区的解释权完全留给数据库和用户。也因此不去读 `@@session.time_zone`。

## 5. 取消与超时

- 执行前起定时器，超时时间为 `queryTimeout`。
- 超时 / 用户取消统一走 `KILL QUERY <thread_id>`（**只杀语句、不杀连接**），经一个懒创建、空闲 60s 关闭的控制连接发送。
- `KILL QUERY` 后置取消标志，让取行循环尽快返回。
- 控制连接不可用或 `KILL QUERY` 失败（权限不足等）时**不动原连接**，明确提示「取消失败，查询仍在服务器上运行」，由用户决定是否断开（需求见 `specs/06-query-editor.md` §9）。
- 错误码 `1317` / `1927` 一律映射为「已取消 / 超时」，不当作未知错误弹窗。

## 6. 保活

- `keepAlive` 开启时定期 ping；ping 与用户查询在同一串行队列上互斥，不会插队。
- ping 失败 → 标记 session 断开，通知 `SessionManager`（状态栏变红 + 「重新连接」）。
- 空闲超时的 session 自动关闭（见 `05-session-management.md` §5）。

## 7. 错误映射

- 连接类错误（网络、认证、SSL 等）与执行类错误（服务器返回的错误码）必须分开，UI 文案不能都是「连接失败」。**数据库名不存在（`1049`）不算连接失败**：连接本身成功，按服务器错误附中文解释（见 `05-session-management.md` §3）。
- 服务器原始 `code` / `SQLSTATE` / `message` **原样展示**，另加一行中文解释，并附带出错语句的前 200 字符。
- 唯一键冲突、语法错误、表不存在、锁等待超时、死锁等属于正常错误路径，不做特殊重试。

## 8. Phase 0 端到端验证

C shim 链路必须通过以下验证才能进入 P1：

1. 能链接并加载 `libmysqlclient.dylib`。
2. 能连上 MySQL。
3. `SELECT 1` 返回一行一列。
4. 一次下发多条语句与单条 `CALL` 都能返回并取完全部结果集。
5. 插入含单引号、反斜杠、emoji、HEX 的数据后读出与写入一致。
6. `KILL QUERY` 能中断长查询，且只杀语句、不杀连接；连接事后仍可继续使用。
7. unbuffered 模式消费 10 万行时内存占用平稳。

入口是 `make smoke`：`scripts/smoke/` 负责起停 Docker MySQL，验证本体在
`Sources/TableLite/Core/MySQL/SmokeRunner.swift`（App 的 `--smoke` 模式，不启动 GUI）。
P1 落地 `MySQLSession` 后，这份验证应当改写为由 `MySQLSession` 驱动 —— 那时它才同时盖住 Swift 封装层。

### 8.1 第 6 项的坑：受害者查询不能用 `SLEEP()`

`SELECT SLEEP(n)` 与 `BENCHMARK()` 被 `KILL QUERY` 后**会吞掉中断**：直接返回正常值、语句成功结束，
客户端拿到 `rc == 0`。拿它们当受害者只会得到「取消链路正常」的假结论。

`SELECT COUNT(*) FROM t, t` 不带条件时也不行 —— MySQL 8.4 直接用行数相乘返回，几百毫秒就跑完。

可用的是**有真实执行计划的查询**，例如 `SELECT COUNT(*) FROM t a, t b WHERE a.id > b.id`：
强制嵌套循环，无法被优化成常数乘法或哈希连接，被 KILL 后返回 `1317 ER_QUERY_INTERRUPTED`。
