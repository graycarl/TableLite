# 09 · 过滤器

对应 TablePlus 的 Filter（行过滤）与 Column Filter（列过滤）。两者都是**纯客户端状态**，只影响生成的 `WHERE` / `SELECT` 列表，不改动数据。

## 1. 行过滤器

### 1.1 状态模型

```swift
struct FilterState: Sendable, Equatable, Codable {
    var conditions: [FilterCondition] = []
    var conjunction: Conjunction = .and          // .and / .or
    var rawSQL: String? = nil                    // 高级模式：直接写 WHERE 片段
    var isVisible: Bool = false
}

struct FilterCondition: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    var column: String
    var operation: FilterOperation
    var value: String            // 用户输入原文
    var value2: String?          // 用于 BETWEEN
    var isEnabled: Bool = true   // 勾选框：参与拼接
}

enum FilterOperation: String, Codable, Sendable, CaseIterable {
    case equal, notEqual
    case contains, notContains
    case startsWith, endsWith
    case greaterThan, greaterOrEqual, lessThan, lessOrEqual
    case isNull, isNotNull
    case between
    case inList              // 逗号分隔
}
```

### 1.2 界面

底部（或作为网格上方可折叠的一条）：

```
┌─ 过滤器 ────────────────────────────────────────────────────────────┐
│ ☑ [ name        ▾ ] [ 包含      ▾ ] [ 张            ]  [ + ] [ − ] │
│ ☑ [ age         ▾ ] [ 大于等于  ▾ ] [ 18             ]  [ + ] [ − ] │
│  组合方式 (•) AND  ( ) OR            [高级/Raw SQL]               │
│                                     [ 重置 ] [ 应用 ]              │
└────────────────────────────────────────────────────────────────────┘
```

- 每行：启用勾选 + 列下拉（可搜索，列很多时必须有搜索）+ 操作符下拉 + 值输入框（`isNull` / `isNotNull` 时禁用）
- `+` 添加一行（`⌘I`），`−` 删除该行（`⇧⌘I`）
- 单行 `Apply`（只应用这一条）—— 简化为直接「应用全部启用的条件」
- `重置` 清空所有条件并重新查询
- `Esc` 关闭面板（保留条件，只是隐藏）

### 1.3 快速过滤

| 触发 | 行为 |
| --- | --- |
| 右键列头 → `按此列筛选` | 新增一条 `column = <该列>` 且 `operation = equal`，值留空并聚焦 |
| 右键单元格 → `按此值筛选` | 新增一条 `column = <该列>`, `equal`, `value = <该单元格值>` 并立即应用 |
| 右键单元格 → `排除此值` | 同上但 `notEqual` |
| 外键单元格点 `↗` | 在新 tab 打开被引用表，并自动加一条 `pk = <值>` 的过滤器 |
| 某列的取值范围已知（ENUM / SET / TINYINT(1)） | 值输入框变为下拉 |

### 1.4 SQL 生成

```swift
enum FilterSQLBuilder {
    static func whereClause(_ state: FilterState,
                            columns: [DataGridColumnModel],
                            literalizer: SQLValueLiteral) throws -> String?
}
```

生成规则：

| 操作符 | SQL |
| --- | --- |
| `equal` | `` `col` = <lit> `` |
| `notEqual` | `` `col` <> <lit> `` |
| `contains` | `` `col` LIKE CONCAT('%', <escaped-value>, '%') ESCAPE '\\' `` |
| `notContains` | `` `col` NOT LIKE CONCAT('%', <escaped-value>, '%') ESCAPE '\\' `` |
| `startsWith` | `` `col` LIKE CONCAT(<escaped-value>, '%') ESCAPE '\\' `` |
| `endsWith` | `` `col` LIKE CONCAT('%', <escaped-value>) ESCAPE '\\' `` |
| `greaterThan` 等 | 上述比较符 + 字面量 |
| `isNull` / `isNotNull` | `` `col` IS NULL `` / `` `col` IS NOT NULL `` |
| `between` | `` `col` BETWEEN <lit1> AND <lit2> `` |
| `inList` | `` `col` IN (<lit1>, <lit2>, …) ``；空列表 → 拒绝并提示 |

要点：

1. **值一律走 `SQLValueLiteral`**，不做任何手工拼接。
2. `LIKE` 的 `%` 与 `_` 必须转义：先把用户输入里的 `\`、`%`、`_` 替换为 `\\`、`\%`、`\_`，再交给 literalizer，并显式加 `ESCAPE '\\'`（避免受 `NO_BACKSLASH_ESCAPES` 影响）。
3. 数字列（`type` 为整数/浮点/`DECIMAL`）且值通过严格数字正则时，字面量不带引号；否则一律带引号（服务器会隐式转换，行为与手写 SQL 一致）。
4. 每条条件可选地用括号包起来，最终用 `AND` / `OR` 连接；**不做**嵌套括号分组（已登记为 `13-open-questions.md` 的 S2）。
5. 空值输入且操作符需要值 → 该条件被跳过，并在 UI 上标黄提示。

### 1.5 Raw SQL 模式

- 提供一个「Raw SQL」切换：直接让用户写 WHERE 片段，例如 `id IN (1,2,3) AND status <> 'deleted'`
- 切换时会提示「Raw SQL 不会被校验，请自行确认语法」
- Raw SQL 与条件行**互斥**：切换时清空另一侧
- Raw SQL 会原样拼进 `WHERE <raw>`；执行前做一次轻量检查（不能含 `;`、不能含 `--` 或 `/*` 之外的注释起始符在字符串之外）——只作为防呆，不作为安全边界（用户本来就能在编辑器里跑任意 SQL）

### 1.6 持久化

过滤器状态跟随 tab 生命周期；可选地保存到 UserDefaults（key: `filter.<connectionID>.<schema>.<table>`），下次打开该表时恢复。默认开启恢复，可在偏好里关。

## 2. 列过滤器

### 2.1 模型

```swift
struct ColumnFilterState: Sendable, Equatable {
    var hiddenColumns: Set<String> = []
    var order: [String]? = nil          // 用户自定义列顺序（本轮不做，留字段）
}
```

### 2.2 界面

`⌥⌘F` 打开的下拉浮层：

```
┌─ 显示的列 ────────────────────┐
│ [ 搜索列… ]     [全选] [全不选]│
│ ☑ id              (主键)      │
│ ☑ name                        │
│ ☐ content         (TEXT)      │
│ ☑ created_at                  │
├───────────────────────────────┤
│       [ 取消 ]  [ 应用 ]      │
└───────────────────────────────┘
```

- 至少保留一列可见（否则禁用「应用」并提示）
- 隐藏列**不影响 SQL**：`SELECT` 仍然取全部列（因为隐藏列之后可能马上要显示，且大字段有截断投影机制）。这是一个刻意的简化：列过滤是纯 UI 行为。
  - 例外：如果隐藏的列是大字段列，仍然会执行 `LEFT()` 投影查询。可以考虑优化为不查询被隐藏的大字段，但那会让「取消隐藏」需要重新查询；保持简单，不做优化。
- 列显隐状态与列宽一起持久化

## 3. 与分页 / 排序 / 暂存的交互

| 交互 | 规则 |
| --- | --- |
| 应用过滤器 | 重置到第 1 页并重新查询 |
| 有未提交改动时改过滤器 | 允许，但会弹提示：「当前有未提交的修改，切换过滤器会重新加载数据（修改会保留）。」暂存区不受影响 |
| 有未提交改动时改排序 | 同上 |
| 过滤器 + 提交 | 提交后按当前过滤器重新查询，被过滤掉的改动行不会出现在结果里（但已提交成功） |
| 过滤器引用了不存在的列 | 生成 SQL 前校验；不存在则报错并高亮该条件 |

## 4. 测试要点

1. `contains` 对 `%`、`_`、`\` 的转义正确
2. `IN` 列表里含引号、含 NULL 文本、含 emoji 时正确
3. `BETWEEN` 缺少第二个值 → 报错而非静默生成错误 SQL
4. 所有条件 `isEnabled == false` → 不生成 `WHERE`
5. `rawSQL` 非空时忽略条件行
6. 空 `IN` 列表 → 抛错
7. 数字列的严格判断：`"12abc"`、`"0x10"`、`"1e5"`、`" 12"` 都必须走字符串字面量
