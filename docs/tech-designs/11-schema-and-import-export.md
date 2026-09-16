# 11 · 元数据、CSV 编解码与导出

## 1. 元数据读取（`MetaRepository`）

需求见 [`specs/02-workspace.md`](../../specs/02-workspace.md) §5 与 [`specs/07-schema-view.md`](../../specs/07-schema-view.md)。

### 1.1 为什么用 `information_schema` 而不是 `SHOW`

- 一次查询能拿到全部对象的带排序结果（`SHOW` 要多次往返）
- 字段更完整（注释、生成列、`COLUMN_TYPE` 原始类型文本、字符集、排序规则）
- 结果集列名稳定，解析简单

### 1.2 查询清单

```sql
-- 库列表（用 SHOW DATABASES 更省事，且只返回有权限的库）
SHOW DATABASES;

-- 库下的对象
SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, TABLE_COMMENT
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = ?
ORDER BY TABLE_TYPE, TABLE_NAME;

-- 例程
SELECT ROUTINE_NAME, ROUTINE_TYPE, DTD_IDENTIFIER, ROUTINE_COMMENT
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = ?
ORDER BY ROUTINE_TYPE, ROUTINE_NAME;

-- 列（表数据视图与结构视图共用）
SELECT COLUMN_NAME, ORDINAL_POSITION, COLUMN_DEFAULT, IS_NULLABLE,
       COLUMN_TYPE, DATA_TYPE, CHARACTER_SET_NAME, COLLATION_NAME,
       COLUMN_KEY, EXTRA, COLUMN_COMMENT, GENERATION_EXPRESSION
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
ORDER BY ORDINAL_POSITION;

-- 索引
SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION,
       CARDINALITY, INDEX_TYPE, INDEX_COMMENT
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
ORDER BY INDEX_NAME, SEQ_IN_INDEX;

-- 外键
SELECT rc.CONSTRAINT_NAME, kcu.COLUMN_NAME,
       kcu.REFERENCED_TABLE_SCHEMA, kcu.REFERENCED_TABLE_NAME, kcu.REFERENCED_COLUMN_NAME,
       rc.UPDATE_RULE, rc.DELETE_RULE
FROM information_schema.REFERENTIAL_CONSTRAINTS rc
JOIN information_schema.KEY_COLUMN_USAGE kcu
  ON kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
 AND kcu.CONSTRAINT_NAME   = rc.CONSTRAINT_NAME
WHERE rc.CONSTRAINT_SCHEMA = ? AND rc.TABLE_NAME = ?
ORDER BY rc.CONSTRAINT_NAME, kcu.ORDINAL_POSITION;

-- 触发器
SELECT TRIGGER_NAME, EVENT_MANIPULATION, ACTION_TIMING, ACTION_STATEMENT
FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = ? AND EVENT_OBJECT_TABLE = ?
ORDER BY TRIGGER_NAME;

-- 建表语句
SHOW CREATE TABLE `schema`.`table`;

-- 视图定义
SHOW CREATE VIEW `schema`.`view`;
```

### 1.3 缓存策略

```swift
actor MetaRepository {
    // key: schema
    private var objectsCache: [String: (items: [DatabaseObject], loadedAt: Date)] = [:]
    // key: "schema.table"
    private var tableMetaCache: [String: (meta: TableMetadata, loadedAt: Date)] = [:]

    func invalidateObjects(schema: String)
    func invalidateTable(schema: String, table: String)
    func invalidateAll()
}
```

| 数据 | TTL | 失效时机 |
| --- | --- | --- |
| 库列表 | 会话内不过期 | 重连时 |
| 对象列表 | 5 分钟 | `⌘R`、执行 DDL 后、重连后 |
| 表结构 | 5 分钟 | `⌘R`、执行 DDL 后 |
| 行数估算 | 30 秒 | 每次翻页 |

- 执行 SQL 后，用 `SQLLexer` 判断语句是否包含 DDL 关键字（`CREATE` / `ALTER` / `DROP` / `TRUNCATE` / `RENAME`），命中则根据语句里的表名失效对应缓存；解析不出表名时保守地失效整个库。
- 系统库过滤：`information_schema` / `performance_schema` / `mysql` / `sys`，由偏好控制是否显示。

### 1.4 `TableMetadata` 结构

```swift
struct TableMetadata: Sendable {
    let schema: String
    let table: String
    let comment: String?
    let columns: [ColumnMeta]
    let indexes: [IndexMeta]
    let foreignKeys: [ForeignKeyMeta]
    let engine: String?

    var primaryKeyColumns: [String]
    var uniqueKeyCandidates: [[String]]      // 全部列 NOT NULL 的唯一索引
    var editability: Editability
}

struct ColumnMeta: Sendable {
    let name: String
    let ordinal: Int
    let rawType: String          // COLUMN_TYPE，如 "enum('a','b')"
    let dataType: String         // DATA_TYPE，如 "enum"
    let isNullable: Bool
    let defaultValue: String?
    let isPrimaryKey: Bool
    let isAutoIncrement: Bool
    let isInvisible: Bool        // EXTRA 含 "INVISIBLE"
    let isGenerated: Bool        // EXTRA 含 "GENERATED"
    let isLarge: Bool            // 需要延迟加载的类型
    let charset: String?
    let collation: String?
    let comment: String?
    let enumValues: [String]?    // 从 rawType 解析
}
```

`columnType`（协议返回的 `enum_field_types`）与 `COLUMN_TYPE`（`information_schema` 的原始文本）在展示时以 `COLUMN_TYPE` 为准（能区分 `tinyint(1)`、`bigint unsigned`、`enum('a','b')`）。

---

## 2. CSV 编解码

需求见 [`specs/08-import-export.md`](../../specs/08-import-export.md)。

**不引入第三方 CSV 库**，实现 `CSVReader` / `CSVWriter`。CSV 本身足够简单，但有几个坑必须覆盖。

### 2.1 写（`CSVWriter`）

```swift
struct CSVWriter {
    let delimiter: Character
    let lineBreak: String
    let quote: Character = "\""
    let nullRepresentation: NullRepresentation   // .emptyString / .literal("NULL")
    let encoding: OutputEncoding                 // .utf8 / .utf8BOM

    func writeHeader(_ names: [String], into: inout Data)
    func writeRow(_ values: [MySQLValue], into: inout Data)
}
```

规则：

- 字段需要加引号的条件（任一满足）：含分隔符、含引号、含 `\n` 或 `\r`、字段首尾有空格
- 引号内的引号用两个引号转义（`"` → `""`）
- `NULL` 按配置输出为空字符串或 `NULL` 字面量
- 二进制值输出为 `0x…` 十六进制文本（CSV 无法承载二进制）
- 浮点数输出服务器返回的原始文本，不做重新格式化（避免精度丢失）
- 输出用 `Data` 缓冲，每 1 MB 刷一次到文件，避免大文件占内存

### 2.2 读（`CSVReader`）

```swift
struct CSVReader {
    init(data: Data, delimiter: Character, hasHeader: Bool, encoding: String.Encoding)
    var header: [String]?
    func forEachRow(_ body: ([String?]) throws -> Void) throws
}
```

必须覆盖的边界：

| 情况 | 期望 |
| --- | --- |
| 引号内的分隔符 | 不切分 |
| 引号内的换行 | 不换行 |
| `""` 转义的引号 | 还原为一个 `"` |
| 字段首尾空格 | **保留原样**（不清洗） |
| 列数少于表头 | 补 `nil`（表示 NULL 还是空串由导入选项决定） |
| 列数多于表头 | 报错并指出行号 |
| BOM | 识别并去掉 |
| CRLF / LF / CR | 都能正确处理 |
| 文件末尾没有换行 | 最后一行仍被读取 |
| 空文件 | 报错「文件为空」 |
| 引号未闭合 | 报错并指出行号 |

### 2.3 编码检测

不引入第三方检测库。策略：

1. 先按 UTF-8 严格解码；成功即用 UTF-8
2. 失败则尝试 GB18030（覆盖 GBK/GB2312）
3. 再失败则尝试 UTF-16（带 BOM 时）
4. 都失败 → 提示用户手动选择编码，并提供 GBK / Big5 / Latin-1 等常见选项

### 2.4 分隔符检测

读前 5 行，统计候选分隔符（`,`、`\t`、`;`、`|`）在各行的出现次数，选择「出现次数在不同行之间最稳定且 > 0」的那个。检测失败时用逗号并提示用户确认。

---

## 3. 导出

### 3.1 流式实现

导出**绝对不能**先把数据全读进内存。实现方式：用 `MySQLSession.query(sql, mode: .unbuffered)`，边收边写。

```
1. 生成查询 SQL：
   - 表导出：SELECT <显式列清单> FROM `db`.`tbl` [WHERE <过滤器>] [ORDER BY <主键>]
   - 结果集导出：直接用原 SQL（但要剥掉 LIMIT，见下）
   - 选中行导出：用行定位键拼 WHERE
2. 建文件（写到临时文件，成功后原子替换目标文件）
3. 写入表头（CSV）或 "[\n"（JSON）
4. 流式消费每一行 → 写一行
5. 收尾（JSON 写 "]\n"）
6. fsync → rename 到目标路径
```

要点：

- 写临时文件再 `rename` 是**必须的**：这样取消导出时不会留下一个看起来完整但实际截断的文件。取消时删除临时文件并提示。
- 每 1000 行检查一次 `Task.isCancelled`，并更新进度（`已写入 N 行（X MB）`）
- 中断（网络断开）时：保留临时文件并改名为 `xxx.partial.csv`，提示用户文件不完整
- 进度与取消通过 `AsyncStream<ExportProgress>` 上报

### 3.2 各格式细节

**CSV**：见 §2.1

**JSON**：流式写数组，每行之间写逗号。每行序列化时用 `MySQLValue` + 列类型决定输出形态：

| 列类型 | JSON 输出 |
| --- | --- |
| 整数 / 浮点 / `DECIMAL` | 数字（不进过浮点转换，直接把原始文本原样写出） |
| 其余 | 字符串 |
| `NULL` | `null` |
| 二进制 | 字符串，内容为 `0x…` |

注意：`DECIMAL` 直接原样输出文本可以避免精度丢失，但 JSON 里会变成字符串——这是刻意的取舍（记录在 `13-open-questions.md`）。

**SQL INSERT**：

```sql
INSERT INTO `db`.`tbl` (`a`, `b`, `c`) VALUES
  (1, 'x', NULL),
  (2, 'y', 0xDEADBEEF);
```

- 值经由 `SQLValueLiteral`（见 `03-mysql-layer.md` §4.2）生成，与变更提交用的完全同一套逻辑
- 批量大小可配置（默认 1，即每行一条语句）
- 可选在文件开头加 `CREATE TABLE`（用 `SHOW CREATE TABLE` 获取）
- 开始时加 `SET NAMES utf8mb4;` 与 `SET FOREIGN_KEY_CHECKS=0;`（可选，默认开）

### 3.3 剥掉 LIMIT

从查询结果集导出时，原始 SQL 可能带 `LIMIT 300`。做法：用 `SQLLexer` 找到最后一个顶层 `LIMIT` 子句并截断。如果解析不确定（例如 `LIMIT` 出现在子查询里、或含 `UNION`），**不修改 SQL**，并在导出面板里明确写出「将导出本次查询实际返回的 N 行」。

这是刻意保守：宁可少导出，不要导出错。

---

## 4. 导入

### 4.1 流程

```
1. 读文件（流式，不整文件读进内存）
2. 解析前 20 行做预览
3. 列映射 → 生成 INSERT 语句集合
4. 按配置执行（事务 / 逐行）
```

### 4.2 生成 INSERT

- 使用 `INSERT INTO ... VALUES (...), (...), ...` 批量提交，每批 500 行（可配）
- 值经过与手工编辑相同的 `SQLValueLiteral` 路径与类型校验
- 类型不匹配时（例如把 `abc` 插进 `int` 列）：
  - 事务模式：报错并回滚
  - 非事务模式：记录失败行，继续
- 失败行收集前 100 条（原行号 + 原内容 + 错误），导入完成后可导出为 CSV

### 4.3 从 CSV 新建表

类型推断规则（读前 1000 行）：

| 观察到的值 | 推断类型 |
| --- | --- |
| 全部匹配 `^-?\d+$` 且长度 ≤ 9 | `int` |
| 全部匹配 `^-?\d+$` 且长度 > 9 | `bigint` |
| 全部匹配 `^-?\d+\.\d+$` | `decimal(20,6)` |
| 全部匹配日期 / 日期时间格式 | `datetime` |
| 其余 | `varchar(n)`，`n` = 该列最长值长度向上取整到 4 的倍数，上限 1024；超过则 `text` |
| 列名重复或为空 | 用 `col_1`、`col_2`… |

推断结果在界面上可逐列修改。执行前把生成的 `CREATE TABLE` 展示出来。

---

## 5. 测试要点

- `CSVReader`：§2.2 表格里的 11 种情况各一个用例
- `CSVWriter`：需要加引号/不需要加引号的边界；`NULL` 的两种表示；CRLF
- 编码检测：UTF-8 / GB18030 / UTF-16 各一份样例文件
- 分隔符检测：逗号 / 制表符 / 分号 / 只有一列（无分隔符）
- 导出：100 万行导出的内存占用 < 100 MB；中途取消不残留完整文件
- `LIMIT` 剥离：简单 `LIMIT`、带 `OFFSET`、`LIMIT` 在子查询里、含 `UNION`、无 `LIMIT`
- 类型推断：5 种规则各一个用例 + 混合类型列
