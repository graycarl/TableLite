# 10 · SQL 编辑器

## 1. 组成

```
┌─ 工具栏 ────────────────────────────────────────────────────────────┐
│ [▶ 执行 ⌘↩] [▶▶ 执行全部 ⇧⌘↩] [停止 ⌘.] │ 字号 − + │ [打开] [另存为] │
├─────────────────────────────────────────────────────────────────────┤
│  1  SELECT id, name                                                  │
│  2  FROM users                                                       │
│  3  WHERE age > 18;                                                  │
│  4                                                                    │
│  5  SELECT COUNT(*) FROM orders;                                     │
├─ 结果区 ────────────────────────────────────────────────────────────┤
│ [结果 1 ×][结果 2 ×][错误 ×]                    共 2 条 · 耗时 42 ms │
├─────────────────────────────────────────────────────────────────────┤
│  （复用只读模式的 DataGridView）                                      │
└─────────────────────────────────────────────────────────────────────┘
```

编辑器与结果区之间用可拖拽分隔条（记住比例）。

## 2. 文本视图

`SQLEditorTextView`：`NSViewRepresentable` 包装 `NSScrollView` + `NSTextView`。

配置：

```swift
textView.isRichText = false
textView.isAutomaticQuoteSubstitutionEnabled = false    // 必须关！否则 " 会变成 "
textView.isAutomaticDashSubstitutionEnabled = false
textView.isAutomaticTextReplacementEnabled = false
textView.isAutomaticSpellingCorrectionEnabled = false
textView.isAutomaticDataDetectionEnabled = false
textView.allowsUndo = true
textView.usesFindBar = true
textView.font = NSFont(name: prefs.editor.fontName, size: prefs.editor.fontSize)
textView.isHorizontallyResizable = false
textView.textContainer.widthTracksTextView = true
textView.smartInsertDeleteEnabled = false
textView.usesAdaptiveColorMappingForDarkAppearance = true
```

**必须关掉的自动替换**是 SQL 编辑器最常见的坑（中文用户尤其容易遇到引号被替换成全角/弯引号）。

行号：左侧一个自绘的 `NSRulerView` 子类（`LineNumberRulerView`），显示行号 + 当前语句起始行的标记。

其他：
- Tab 键插入 `editor.tabWidth` 个空格（默认 4）
- 自动缩进：换行时继承上一行前导空白；`(` / `,` 后可稍微增加缩进（简单实现，不做完整格式化）

## 3. 语法高亮

`SQLLexer`：手写单向扫描器，输出 `[(range, TokenKind)]`。

```swift
enum TokenKind {
    case keyword        // SELECT / FROM / WHERE / INSERT / …
    case function       // COUNT / NOW / JSON_EXTRACT / …（常用函数表，约 200 个）
    case type           // INT / VARCHAR / DATETIME / …
    case string         // '…' 与 "…"
    case backtick       // `…`
    case number
    case comment        // -- … / # … / /* … */
    case variable       // @var / @@global.var
    case parameter      // ? （即使不做查询参数，也高亮）
    case operatorSymbol // = <> <= >= + - * / %
    case punctuation
    case identifier
    case plain
}
```

实现要点：
1. 必须正确处理：
   - 字符串内的 `--`（不是注释）
   - 字符串内的 `;`（不拆语句）
   - 转义：`''`、`\'`、`""`、`\"`（同时兼容 `NO_BACKSLASH_ESCAPES`）
   - 反引号内的所有内容（包括 `;`、`--`）
   - `/* */` 嵌套（MySQL 不支持嵌套，但 `/*! … */` 是版本注释，要整体当注释处理）
   - `#` 注释（MySQL/src 特有）
2. 增量着色：`NSTextStorageDelegate` 的 `didProcessEditing` 里，只对**受影响的段落范围**重新着色（按段落对齐），避免全文重扫。
3. 单次扫描 5000 行的预算 ≤ 15 ms。
4. 颜色主题跟随系统深浅色，用两套 `NSColor`（不做用户自定义，理由见 [`specs/00-scope.md`](../../specs/00-scope.md) §2.2）。
5. 高亮**当前语句**：光标所在语句的所有行加一层极淡背景（在 `NSTextView.drawBackground` 里画）。

## 4. 语句拆分

`StatementSplitter`：与 lexer 共享扫描逻辑，输出：

```swift
struct SQLStatement: Sendable, Equatable {
    let index: Int
    let range: NSRange           // 在原文中的范围
    let text: String             // 已去除首尾空白与结尾分号？
    let kind: StatementKind      // .query / .dml / .ddl / .other
}

enum StatementSplitter {
    static func split(_ sql: String) -> [SQLStatement]
    static func statement(at location: Int, in statements: [SQLStatement]) -> SQLStatement?
}
```

规则：
- 分号分隔；**忽略**字符串、反引号、注释内的分号
- 结尾没有分号的最后一段也算一条语句（非空时）
- 空语句 / 纯注释段跳过
- `text` 保留原始内容（含结尾分号），下发给服务器时不需要再补分号
- `kind` 由 `SQLLexer` 的第一个关键字决定，用于只读模式拦截与历史分类

## 5. 执行

### 5.1 执行哪段

| 快捷键 | 行为 |
| --- | --- |
| `⌘↩` | 有选区 → 执行选区；无选区 → 执行光标所在语句（`StatementSplitter.statement(at:)`） |
| `⇧⌘↩` | 执行全部语句 |
| 工具栏下拉 | 可把默认行为切换为「执行全部」（记在 UserDefaults） |

### 5.2 下发方式

- 一次把所有要执行的语句**拼成一段脚本**（保留语句间的分号）交给 `MySQLSession.executeScript`
- 连接已开 `CLIENT_MULTI_STATEMENTS`，服务器会依次执行并返回多个结果集（`03-mysql-layer.md` §2.1）
- **不**自己逐条下发，因为那样会丢失「服务器一次处理一批」的语义且多一次往返
- 但如果脚本里含有会改变会话状态的语句（`USE`、`SET`）且后面还有依赖它的语句 → 顺序执行由服务器保证，无需特殊处理

### 5.3 执行中的 UI

- 工具栏的 `执行` 变成 `停止`（`⌘.`）
- 状态栏显示 `正在执行… 已接收 12,480 行（2.1 MB）（3.4 s）`
- 结果标签边收边建，行数据**流式**追加到结果网格（`.unbuffered` 模式）
- 超过 10 万行时自动提示「结果较大，可随时停止」

### 5.4 单条语句出错

- 服务器在 `mysql_next_result` 循环中返回错误 → 该语句标记为失败，**后续语句继续执行**（与 `mysql --force` 一致）
  - 这是刻意选择：方便跑迁移脚本时一次看到全部错误
  - 但**提供偏好** `editor.stopOnError`（默认 **true**）：默认遇到第一个错误就停止，并在 Console Log 记录；用户可关闭以继续
  - 实现方式：错误发生后由 Swift 侧决定是否 `mtl_conn_cancel`（走取消路径，剩余结果集被丢弃）
- 出错标签显示为红色，内容是错误码 + SQLSTATE + message

## 6. 结果标签

```swift
struct StatementResult: Identifiable {
    let id: UUID
    let statementIndex: Int
    let sql: String
    var outcome: Outcome

    enum Outcome {
        case pending
        case rows(MySQLResultSet)          // 只读网格
        case affected(UInt64, lastInsertID: UInt64?)
        case failed(MySQLError)
        case cancelled
    }
}
```

标签栏规则：

- 标签文本：`结果 N`（查询）/ `完成`（影响行数）/ `错误`（失败）
- 标签颜色：查询=默认，成功非查询=绿点，失败=红点
- 标签数量 > 24 时折叠：前 23 个 + 一个 `…` 下拉
- 点击标签切换下方网格；结果网格**只读**（需求见 [`specs/00-scope.md`](../../specs/00-scope.md) 的 D10），但支持：排序（本地排序）、复制、导出、快速查看、列宽调整、列过滤器
  > 结果集是内存里的数据，排序就是本地对 `rows` 排序，不重新查询
- 右键标签：`关闭` / `关闭其他` / `复制语句` / `复制结果`
- 无结果集但有影响行数时，标签页显示一个简单的成功面板：`影响 3 行，耗时 12 ms，last_insert_id = 42`

## 7. 查询历史

左侧栏底部的入口（布局见 [`specs/02-workspace.md`](../../specs/02-workspace.md) §1）打开的历史 tab：

```
┌─ 查询历史 ─────────────────────────────────────────────────┐
│ [ 搜索 ]  [全部连接 ▾]  [今天 ▾]              [清空历史]   │
├────────────────────────────────────────────────────────────┤
│ 14:32:07  ✓  42 ms   1,204 行   SELECT id, name FROM …     │
│ 14:31:55  ✗  3 ms               UPDATE users SET …         │
│ 昨天 18:02  ✓  812 ms  3 行      INSERT INTO orders …       │
├────────────────────────────────────────────────────────────┤
│ 单击 → 在下方预览完整 SQL                                   │
│ 双击 → 插入到当前查询 tab                                    │
│ 右键 → 复制 / 在新 tab 打开 / 删除该条                       │
└────────────────────────────────────────────────────────────┘
```

- 数据来自 `history.sqlite3`（`02-persistence.md` §4）
- 只记录 SQL 编辑器的语句；网格分页与元数据查询不记录
- 搜索为 SQL 子串匹配（`LIKE '%kw%'`），结果限 500 条
- 清空 = 删除当前连接的记录（按住 `⌥` 点击清空所有连接）

## 8. Console Log

侧栏入口打开的独立 tab：

```
┌─ Console Log ──────────────────────────────────────────────┐
│ [全部 ▾] (全部 / 仅数据语句 / 仅元数据)     [复制] [清空]  │
├────────────────────────────────────────────────────────────┤
│ 14:32:07.123 [data]  app_dev  42 ms   1204 行               │
│   SELECT `id`,`name` FROM `app_dev`.`users` ORDER BY …      │
│ 14:32:06.998 [meta]  app_dev  3 ms                          │
│   SELECT COLUMN_NAME, … FROM information_schema.COLUMNS …   │
│ 14:32:06.541 [data]  app_dev  ✗ 1064                        │
│   SELECT * FORM users                                       │
└────────────────────────────────────────────────────────────┘
```

- 记录范围：**所有**下发到服务器的语句（含 `START TRANSACTION` / `COMMIT` / `KILL QUERY`）
- 标签：`[data]` 用户发起的语句；`[meta]` 客户端自动发的（元数据、分页、ping、事务控制）
- 每条可展开看完整 SQL + 结果概要
- 内存环形缓冲 5000 条；超出丢弃最旧的
- 默认不落盘；偏好可开（`02-persistence.md` §5）
- 该 tab 打开时自动跟随滚动到底部；用户向上滚动后暂停自动跟随，显示「回到底部」按钮

## 9. 脚本文件

| 操作 | 行为 |
| --- | --- |
| `⌘O` | 打开 `.sql` / `.txt` 文件到新的查询 tab |
| `⇧⌘S` | 当前脚本另存为 |
| 自动草稿 | 每个查询 tab 的内容防抖 1s 写入 `drafts/<tabID>.sql`，重启恢复 |
| 关闭未保存 tab | 若内容是草稿（从未另存）则不提示；若曾关联文件且有改动 → 提示保存 |

## 10. 只读模式拦截

连接为只读时（需求见 [`specs/09-readonly-mode.md`](../../specs/09-readonly-mode.md)）：

1. 发送前用 `SQLStatement.kind` 过滤：`.dml` / `.ddl` → 拒绝
2. 混合脚本中只执行安全的语句，被拒绝的语句在结果标签里标红说明
3. UI 上把「执行」按钮旁的提示改为「只读模式：仅允许 SELECT / SHOW / EXPLAIN / DESC」

## 11. 测试要点

1. `StatementSplitter`：字符串内分号、反引号内分号、`--` 注释内分号、`#` 注释、行末无分号、连续分号、只有注释、BOM、CRLF
2. `SQLLexer`：`'a''b'`、`'a\'b'`、`` `a`b` ``、`/*!40101 SET … */`、`@@version`、`0x1F`、`1e5`、`-- comment` 在字符串内
3. `statement(at:)` 在边界位置（分号上、注释里、文件末尾）的行为
4. 只读模式对 `INSERT`、`/* comment */ INSERT`、`WITH x AS (…) INSERT` 都要拦得住（**注意 CTE 开头的 INSERT**）
