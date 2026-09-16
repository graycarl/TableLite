# 03 · MySQL 数据访问层

依赖：Homebrew `mysql-client` 提供的 `libmysqlclient`（见 `12-build-and-deps.md`）。
分两层：**C shim（`CMySQLClient`）** 负责隔离 C 宏、内存与线程；**Swift `MySQLSession`** 负责异步、类型映射与业务语义。

## 1. 设计原则

1. **不用 prepared statement。**
   所有写入都生成 SQL 字面量下发。理由有三：
   - 用户点了 Preview 就要看到**最终下发的原文**，prepared statement 会让 Preview 与实际执行不一致；
   - `mysql_real_escape_string` 会根据服务器当前的 `sql_mode`（是否 `NO_BACKSLASH_ESCAPES`）与连接 charset 正确转义，比自己转义安全；
   - 二进制数据用 `0x…` 十六进制字面量，完全不经过转义路径。
2. **读多行数据走 text protocol**（`mysql_store_result` / `mysql_use_result`），值以「原始字节 + 列元数据」的形式交给上层，类型解释由 Swift 侧按列类型决定。这与 `mysql` CLI 的行为一致，避免二进制协议的类型坑。
3. **C 与 Swift 的边界只传指针数组，不传 JSON**，避免编解码开销与转义 bug。
4. **一行数据在回调返回前必须被 Swift 复制走**，因为 `mysql_fetch_row` 的缓冲区会被下一次调用复用。
5. **转义策略固定**：字符串值走 `mysql_real_escape_string`，二进制值走 `0x…` 十六进制字面量（完全不经过转义路径），不写自制的转义函数。细节见 §4.2。

## 2. C shim API（`Sources/CMySQLClient/include/CMySQLClient.h`）

```c
#ifndef C_MYSQL_CLIENT_H
#define C_MYSQL_CLIENT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MTLConn MTLConn;

/* ---------------- 列元数据 ---------------- */
typedef struct {
    const char  *name;            /* 结果集列名（别名） */
    const char  *original_name;   /* 原始列名 org_name */
    const char  *table;           /* 结果集中的表名（可能是别名） */
    const char  *original_table;  /* 原始表名 org_table */
    const char  *database;        /* 所属库 db */
    unsigned int type;            /* enum_field_types */
    unsigned int flags;           /* NOT_NULL_FLAG / PRI_KEY_FLAG / UNSIGNED_FLAG /
                                     BINARY_FLAG / AUTO_INCREMENT_FLAG / BLOB_FLAG ... */
    unsigned int charset_nr;      /* 字符集编号，63 = binary */
    unsigned int length;          /* 显示宽度 */
    unsigned int decimals;        /* 小数位数 */
    unsigned int is_null;         /* 结果集该列是否一定为 NULL（IS_NULL_FLAG 不算，仅占位） */
} MTLColumn;

/* ---------------- 行 ---------------- */
typedef struct {
    int                  result_index;   /* 第几个结果集，从 0 开始 */
    long long            row_index;      /* 结果集内行序号，从 0 开始 */
    int                  column_count;
    const char *const   *values;         /* values[i] == NULL 表示 SQL NULL */
    const unsigned long *lengths;        /* 每列的字节长度（不含结尾 \0） */
} MTLRow;

/* ---------------- 结果集开始 ---------------- */
typedef struct {
    int         result_index;
    int         column_count;      /* >0 表示这是一个结果集；==0 表示这是 OK/影响行数 */
    long long   affected_rows;
    unsigned long long last_insert_id;
    const MTLColumn *columns;      /* column_count == 0 时为 NULL */
} MTLResultSet;

/* ---------------- 回调 ---------------- */
typedef struct {
    void *ctx;
    /* 每个结果集开始时回调一次 */
    void (*on_result_set)(void *ctx, const MTLResultSet *rs);
    /* 每行回调一次；返回非 0 表示上层要求中止（shim 会发 KILL QUERY 并返回 2） */
    int  (*on_row)(void *ctx, const MTLRow *row);
    /* 语句级错误：shim 记录后继续处理后续结果集（若服务器允许） */
    void (*on_statement_error)(void *ctx, int result_index,
                               unsigned int code, const char *sqlstate,
                               const char *message);
} MTLCallbacks;

/* ---------------- 连接生命周期 ---------------- */
MTLConn *mtl_conn_create(void);
void     mtl_conn_free(MTLConn *c);

/* 连接前可调用 */
void mtl_conn_set_ssl(MTLConn *c, int use_ssl, int skip_verify);
void mtl_conn_set_connect_timeout(MTLConn *c, unsigned int seconds);
void mtl_conn_set_read_write_timeout(MTLConn *c, unsigned int seconds);

/*
 * 建立连接。password / database / charset / unix_socket 均可为 NULL。
 * 返回 0 成功；非 0 失败，错误文本写入 err（容量 MTL_ERRBUF_SIZE）。
 *
 * 用显式参数而不是 JSON：C 侧解析 JSON 需要一个 JSON 库或者手写解析器，
 * 得不偿失；参数就这么多，直接传更清楚。
 */
int  mtl_conn_open(MTLConn *c,
                   const char *host, unsigned int port,
                   const char *user, const char *password,
                   const char *database, const char *charset,
                   const char *unix_socket,
                   char *err, size_t err_len);
void mtl_conn_close(MTLConn *c);
int  mtl_conn_is_open(MTLConn *c);

/* 保活。返回 0 正常 */
int  mtl_conn_ping(MTLConn *c);

/* 服务器线程 id，用于从另一条连接发 KILL QUERY */
unsigned long mtl_conn_thread_id(MTLConn *c);

/* 最近一次 errno / error / sqlstate。指针在下一次调用前有效 */
unsigned int  mtl_conn_errno(MTLConn *c);
const char   *mtl_conn_error(MTLConn *c);
const char   *mtl_conn_sqlstate(MTLConn *c);

/* 取消后连接可能已不同步（流式读取被打断），上层应当重建连接 */
int mtl_conn_needs_reset(MTLConn *c);

/* 客户端库版本，不需要已建立的连接 */
const char *mtl_client_version(void);

/* ---------------- 执行 ---------------- */
/*
 * 执行一段 SQL（可含多条语句，连接时已开启 CLIENT_MULTI_STATEMENTS）。
 *   unbuffered = 0：mysql_store_result（整批读进内存，适合分页查询）
 *   unbuffered = 1：mysql_use_result（逐行流式，适合导出/大结果）
 * 返回：
 *   0  全部结果集正常结束
 *   2  被 on_row 返回非 0 中止，或外部调用了 mtl_conn_cancel
 *   3  至少一条语句出错（错误已通过 on_statement_error 回调，也可能在 err 里）
 *  -1  参数非法
 */
int mtl_conn_query(MTLConn *c, const char *sql, size_t sql_len, int unbuffered,
                   const MTLCallbacks *cb, char *err, size_t err_len);

/*
 * 转义字符串（不含首尾引号）。必须在 mtl_conn_open 成功后调用。
 * 返回写入 out 的字节数；out_len 不足时返回需要的长度（不写入）。
 */
size_t mtl_conn_escape(MTLConn *c, const char *in, size_t in_len,
                       char *out, size_t out_len);

/* 取服务器版本等信息 */
const char *mtl_conn_server_version(MTLConn *c);
const char *mtl_conn_server_info(MTLConn *c);

#ifdef __cplusplus
}
#endif
#endif /* C_MYSQL_CLIENT_H */
```

### 2.1 `CMySQLClient.c` 实现要点

1. `MTLConn` 内部持有 `MYSQL *`、`unsigned long thread_id`、`char last_error[512]`、`unsigned int last_errno`、`char last_sqlstate[8]`、`int cancel_requested`（`volatile sig_atomic_t` 语义，仅同队列读写，但允许从其他线程置位后由本队列轮询）。
2. `mtl_conn_open`：
   - `mysql_init` → `mysql_options(MYSQL_OPT_CONNECT_TIMEOUT / MYSQL_OPT_READ_TIMEOUT / MYSQL_OPT_WRITE_TIMEOUT / MYSQL_SET_CHARSET_NAME)`
   - 在 `mysql_real_connect` 前用 `MYSQL_OPT_SSL_MODE` 控制 SSL：
     默认 `SSL_MODE_PREFERRED`（服务器不支持时自动回退）；
     要求 TLS 但跳过校验用 `SSL_MODE_REQUIRED`；其余用 `SSL_MODE_VERIFY_CA`。
   - `mysql_real_connect` 之后立刻：
     - `mysql_set_character_set(conn, charset)`（默认 `utf8mb4`）—— 这决定 `mysql_real_escape_string` 的行为，**不能省**
     - `mysql_options(MYSQL_OPT_LOCAL_INFILE, 0)` 禁止 `LOAD DATA LOCAL`（安全）
     - **不**擅自改用户的 `sql_mode` / 会话变量
   - 记录 `mysql_thread_id(conn)`
   - 不启用库层的自动重连（`MYSQL_OPT_RECONNECT`）：重连由上层显式控制
3. `mtl_conn_query`：
   ```
   mysql_real_query(conn, sql, sql_len)
     ↓ 无结果集 → mysql_affected_rows / mysql_insert_id → on_result_set(column_count=0)
     ↓ 有结果集 → mysql_field_count / mysql_fetch_fields → 组装 MTLColumn[] → on_result_set
                  mysql_store_result 或 mysql_use_result
                  循环 mysql_fetch_row + mysql_fetch_lengths → on_row
                  结束：检查 mysql_errno == 0
     ↓ while (mysql_next_result(conn) == 0) 继续处理下一个结果集
   ```
   - `MYSQL_FIELD.name` 等字符串指针的生命周期与结果集一致 → 在回调**期间**直接传指针是安全的；
     必须在文档与代码注释里写明「这些指针只在本次回调内有效」，并要求上层立刻复制。
     （数值字段如 `type` / `flags` / `charsetnr` 是值拷贝，不存在这个问题。）
   - `mysql_fetch_row` 返回的字符串可能含 `\0`（BLOB），必须用 `mysql_fetch_lengths` 取长度，**不能**用 `strlen`。
   - 每条语句出错时立即调用 `on_statement_error` 并记录；因为 `mysql_next_result` 在错误后仍可用，继续循环（行为与 `mysql --force` 一致，是否继续由上层决定）。
4. **取消**：提供 `void mtl_conn_cancel(MTLConn *c)`（在头文件里补上）。它只是把 `cancel_requested = 1`，随后：
   - 若当前在 `mtl_conn_query` 的 `on_row` 循环里 → 检查标志后 `mysql_kill(conn, thread_id)` 并返回 2
   - 若当前没在跑查询 → 由 Swift 层用**控制连接**发 `KILL QUERY <thread_id>`
   - Swift 层的做法统一为：`MySQLSession.cancel()` 先用控制连接发 `KILL QUERY`，再置 `cancel_requested`（双保险）
5. 内存：所有 `malloc` 都必须有对应 `free`，且在错误路径上也释放。使用单一 `goto cleanup` 风格。

## 3. Swift 封装（`MySQLSession`）

```swift
struct MySQLConfig: Sendable, Codable {
    var host: String
    var port: UInt16
    var user: String
    var database: String?
    var charset: String = "utf8mb4"
    var useSSL: Bool = true
    var sslSkipVerify: Bool = false
    var connectTimeout: Int = 10
    var queryTimeout: Int = 300
    var keepAlive: Bool = true
    var keepAliveInterval: Int = 30
    var unixSocket: String?
}

enum QueryMode: Sendable { case buffered, unbuffered }

enum QueryEvent: Sendable {
    case resultSetBegin(index: Int32, columns: [MySQLColumn])   // columns 为空表示 OK 型结果
    case row(index: Int32, values: [MySQLValue])
    case affected(index: Int32, rows: UInt64, lastInsertID: UInt64)
    case statementError(index: Int32, error: MySQLError)        // 单条语句失败，循环继续
    case finished(cancelled: Bool)
}

actor MySQLSession {
    init(config: MySQLConfig, password: String?, endPoint: EndPoint)
    // EndPoint: .direct(host:port:) 或 .tunnel(localPort:)  —— SSH 隧道时用后者的 127.0.0.1:localPort

    var isOpen: Bool { get }
    var serverVersion: String? { get }
    var threadID: UInt64 { get }

    func open() async throws
    func close() async
    func ping() async throws

    func query(_ sql: String, mode: QueryMode = .buffered) -> AsyncThrowingStream<QueryEvent, Error>
    func fetchPage(_ sql: String) async throws -> MySQLResultSet        // buffered 便捷封装
    func executeScript(_ sql: String) async throws -> ScriptReport       // 多语句，收集每个结果
    func cancel() async
    func escape(_ s: String) async throws -> String
}
```

### 3.1 串行队列与 continuation

```swift
private let queue: DispatchQueue           // 每 session 一条，label 含 connection id
private let handle: UnsafeMutablePointer<MTLConn>   // 持有，deinit 释放
```

`query` 内部：

```swift
return AsyncThrowingStream { continuation in
    queue.async {
        var cb = MTLCallbacks(ctx: Unmanaged.passUnretained(box).toOpaque(), ...)
        // C 回调 → 立即把值复制成 Swift 类型 → continuation.yield(...)
        let rc = mtl_conn_query(handle, sql, sql.utf8.count, mode == .unbuffered ? 1 : 0, &cb, ...)
        // 把 rc 映射成 finish(throwing:) / finish()
    }
}
```

- 回调里 `MTLColumn` → `MySQLColumn` 时，所有 `const char *` 都必须 `String(cString:)` 复制。
- `MTLRow` → `[MySQLValue]`：对每列用 `UnsafeBufferPointer<UInt8>(start:length:)` 复制成 `[UInt8]`，再包成 `MySQLValue`。
- 回调是同步的且运行在 `queue` 上，因此 `continuation.yield` 会自然产生背压？**不会**。需要显式背压：
  - 若要支持背压，`on_row` 应当阻塞等待，但 C 回调里不能 await。
  - 折中方案（本设计采用）：`on_row` 里把行写入一个**有界缓冲**（容量 2000 行）；缓冲满且消费者未跟上时，`on_row` 调用 `Condition.wait` 阻塞（这在串行队列上是安全的，因为释放操作由消费者在别的队列完成）。
  - 简化实现（第一阶段）：不阻塞，直接 `continuation.yield`，依赖 `AsyncStream` 的 `.bufferingNewest(2000)` 策略，超出时丢弃旧行并置 `dropped` 标记。对超大结果集会有内存压力，但配合分页查询已足够。
  - **必须**在 `13-open-questions.md` 记录「背压未做严格实现」（已登记为 L1）。

### 3.2 结果集模型

```swift
struct MySQLColumn: Sendable, Identifiable {
    let id: Int
    let name: String            // 结果集列名
    let originalName: String
    let table: String
    let originalTable: String
    let database: String
    let type: MySQLType
    let flags: MySQLColumnFlags
    let charsetNumber: UInt32
    let length: UInt32
    let decimals: UInt32

    var isBinary: Bool { charsetNumber == 63 }
    var isNullable: Bool { !flags.contains(.notNull) }
    var isPrimaryKey: Bool { flags.contains(.primaryKey) }
    var isUnsigned: Bool { flags.contains(.unsigned) }
    var isAutoIncrement: Bool { flags.contains(.autoIncrement) }
}

struct MySQLResultSet: Sendable {
    var columns: [MySQLColumn]
    var rows: [[MySQLValue]]
    var affectedRows: UInt64
    var lastInsertID: UInt64
    var isQuery: Bool { !columns.isEmpty }
}

enum MySQLValue: Sendable, Equatable {
    case null
    case bytes([UInt8])          // 原始字节；按列的 isBinary / type 决定如何解释
    case truncated(bytes: [UInt8], originalByteCount: Int)   // 服务端 LEFT() 投影或客户端截断

    var isNull: Bool { if case .null = self { true } else { false } }
}
```

**为什么用原始字节**：text protocol 返回的就是字节串；是否当字符串、数字、日期、二进制处理，完全由列元数据决定，放在展示层做可以让「值 → 显示文本 → 编辑文本 → SQL 字面量」这条链路单一且可测。

## 4. 类型映射

### 4.1 显示（`MySQLValue` + `MySQLColumn` → 显示文本）

| MySQL type | 显示 | 编辑控件 | NULL |
| --- | --- | --- | --- |
| `TINYINT` / `SMALLINT` / `MEDIUMINT` / `INT` / `BIGINT` | 十进制文本；`UNSIGNED` 正常 | 单行文本（数字键盘） | `NULL`（斜体灰） |
| `TINYINT(1)`（等价 boolean 约定） | `0` / `1`（可选显示为复选框，见下） | 复选框 | 复选框三态 |
| `DECIMAL` / `NUMERIC` | 原样文本（不做浮点转换） | 单行文本 | ✔ |
| `FLOAT` / `DOUBLE` | 原样文本 | 单行文本 | ✔ |
| `BIT` | `b'1010'` 形式（`bin` 显示） | 单行文本 | ✔ |
| `DATE` | `YYYY-MM-DD` | 日期选择器 + 文本 | ✔ |
| `TIME` | `HH:MM:SS[.ffffff]` | 文本 | ✔ |
| `DATETIME` / `TIMESTAMP` | `YYYY-MM-DD HH:MM:SS[.ffffff]` | 日期时间选择器 + 文本 | ✔ |
| `YEAR` | `YYYY` | 文本 | ✔ |
| `CHAR` / `VARCHAR` | 原样（超长截断） | 单行/多行文本 | ✔ |
| `TEXT` / `TINYTEXT` / `MEDIUMTEXT` / `LONGTEXT` | 原样（超长截断） | 多行文本 | ✔ |
| `JSON` | 单行预览；Quick Look 格式化 | 多行文本（不自动美化，避免改动语义） | ✔ |
| `BINARY` / `VARBINARY` | `0xDEADBEEF`（超长显示 `0xDEAD… (12.3 KB)`） | hex 文本 | ✔ |
| `BLOB` 系列 | `«BLOB 12.3 KB»` | Quick Look / 导入文件 / hex 编辑 | ✔ |
| `GEOMETRY` / `POINT` … | `«GEOMETRY 25 B»`，Quick Look 显示 hex | 只读（不做 WKT 转换） | ✔ |
| `ENUM` | 原值文本 | 下拉（选项从 `information_schema.COLUMNS.COLUMN_TYPE` 解析） | ✔ |
| `SET` | 逗号分隔原值 | 多选 | ✔ |
| 未知类型 | 原样文本 | 单行文本 | ✔ |

`TINYINT(1)` 是否显示成复选框由偏好 `grid.tinyInt1AsBool` 控制，**默认关闭**（避免误判，很多项目用 `TINYINT(1)` 存 0/1/2）。

### 4.2 字面量生成（`SQLValueLiteral`）

| 输入 | 输出 |
| --- | --- |
| `.null` | `NULL` |
| 数字列 + 合法数字文本 | 数字原文（如 `42`、`-3.14`）；不合法则回退到字符串字面量并给出警告 |
| 字符串列 | `'` + `mysql_real_escape_string` 结果 + `'`；若连接 charset 非 utf8 系则加 `_utf8mb4` introducer |
| 二进制列 | `0x` + 大写 hex（无需转义，绝对安全）；空串为 `X''` |
| 日期时间列 | `'2025-01-01 00:00:00'`（仍走转义） |

规则：
- **数字判断必须用严格正则**：`^-?\d+$` 或 `^-?\d+\.\d+$`（不允许 `1e5`、`0x1`、前导 `+`、空白）。
- 任何无法确定的情况一律走字符串字面量，永不拼接未验证的内容。
- 函数是纯的，单元测试必须覆盖：单引号、双引号、反斜杠、换行、`\0`、emoji、`NO_BACKSLASH_ESCAPES` 场景（由 C shim 保证，测试用 mock escapers）。

## 5. 查询超时与取消

```
执行前：起一个 DispatchSourceTimer，超时时间为 config.queryTimeout
超时触发：
  1. 通过「控制连接」发 KILL QUERY <thread_id>
     控制连接 = 用同一份连接参数另开一个 MySQLSession（懒创建，空闲 60s 后关闭）
  2. 置 cancel_requested，让 on_row 尽快返回非 0
  3. continuation.finish(throwing: .timeout(seconds:killed:))
```

- `KILL QUERY` 只杀语句不杀连接；成功后在 Console Log 里打一条 `[meta] KILL QUERY`。
- 用户点「取消」按钮 → 与超时同路径，错误为 `.cancelled`。
- 若控制连接不可用（例如权限不足），退化为 `mysql_kill`（`KILL CONNECTION`），此时连接作废、标记为需重连，并明确提示用户。
- 错误码 `1317 ER_QUERY_INTERRUPTED` / `1927 ER_CONNECTION_KILLED` 一律映射为 `.cancelled` 或 `.timeout`，不当作未知错误弹出。

## 6. 保活

- 每个 `MySQLSession` 在 `keepAlive == true` 时启动一个 30s 定时器，队列上执行 `mtl_conn_ping`。
- ping 失败 → 标记 session 为 `disconnected`，向 `SessionManager` 发通知（UI 状态栏变红，提示「重新连接」）。
- ping 与用户查询互斥（同在串行队列上），保证不会插队。
- 空闲超过 5 分钟的 session 自动 `close`（释放服务器连接），下次使用前自动重连。

## 7. 错误映射

| libmysqlclient errno | Swift | UI 提示 |
| --- | --- | --- |
| `2002` / `2003` / `2005` | `.connectFailed` | 无法连接到服务器（host/port 或网络问题） |
| `2006` `CR_SERVER_GONE_ERROR` | `.notConnected` | 服务器已断开连接，正在重连… |
| `2013` `CR_SERVER_LOST` | `.notConnected` | 连接丢失（可能查询超时或被 kill） |
| `2026` SSL 相关 | `.connectFailed` | SSL 握手失败（可尝试关闭 SSL 或勾选「跳过证书校验」） |
| `1045` | `.connectFailed` | 用户名或密码错误 |
| `1049` | `.connectFailed` | 数据库不存在 |
| `1130` | `.connectFailed` | 该主机不允许连接（服务器 host 白名单） |
| `1062` | `.server` | 唯一键冲突（Commit 时展示具体值） |
| `1064` | `.server` | SQL 语法错误（光标定位到出错位置若可解析） |
| `1146` | `.server` | 表不存在 |
| `1205` | `.server` | 锁等待超时 |
| `1213` | `.server` | 死锁，事务已回滚 |
| `1317` / `1927` | `.cancelled` | 查询已取消 |
| 其他 | `.server` | 原样展示 message |

展示格式统一为：
```
[错误 1062] SQLSTATE 23000
Duplicate entry '1' for key 'PRIMARY'
```
并附带该语句的前 200 字符。

## 8. 端到端最小验证（Phase 0 完成标准）

写一个命令行小 demo（放在 `scripts/smoke/` 下，或用 `swift run` 临时 target）验证：

1. 能链接并加载 `libmysqlclient.dylib`
2. `mtl_conn_open` 连上本机 MySQL
3. `SELECT 1` 返回一行一列
4. `SELECT 1; SELECT 2` 返回两个结果集
5. 建临时表 → 插入含 `'`、`\`、emoji、HEX 的数据 → 读出对比一致
6. `SELECT SLEEP(10)` 能被 `KILL QUERY` 中断
7. `SELECT * FROM` 一张有 10 万行的表，unbuffered 模式内存占用平稳

以上 7 条全过才进入 P1。
