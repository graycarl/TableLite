# 08 · 变更暂存（Pending Changes）

这是本项目**最核心**的机制：GUI 上的任何数据修改都不直接落库，而是先进入当前 tab 的暂存区，用户确认后才以事务形式提交。

## 1. 作用域

- **每个数据网格 tab 一个独立的 `PendingChangeStore`**（需求见 [`specs/04-data-editing.md`](../../specs/04-data-editing.md) §8）
- Commit / Discard 只影响当前 tab
- 切换到别的 tab、切换到别的连接，都不会丢掉暂存（tab 还活着，store 就还在）
- 关闭 tab / 关闭 App 时有未提交改动 → 确认弹窗（选项：`提交` / `放弃` / `取消关闭`）

## 2. 数据模型

```swift
enum PendingChange: Identifiable, Sendable, Equatable {
    case insert(InsertChange)
    case update(UpdateChange)
    case delete(DeleteChange)

    var id: UUID { … }
    var tableRef: TableRef { … }        // { schema, table }
}

struct TableRef: Hashable, Sendable, Codable {
    let schema: String
    let table: String
    var quoted: String { "`\(schema)`.`\(table)`" }
}

struct InsertChange: Sendable, Equatable {
    let id: UUID
    var values: [String: EditValue]      // 列名 → 值；未出现的列不在 INSERT 里
}

struct UpdateChange: Sendable, Equatable {
    let id: UUID
    var rowIdentity: RowIdentity
    var sets: [String: EditValue]        // 列名 → 新值
}

struct DeleteChange: Sendable, Equatable {
    let id: UUID
    var rowIdentity: RowIdentity
}

/// 行定位信息：有主键时只用主键；否则用唯一索引
struct RowIdentity: Hashable, Sendable, Codable {
    /// 提交到 WHERE 的键值对（原始字节的 base64 编码，保证 Hashable 且保真）
    var keys: [(column: String, value: EditValue)]
    /// 用于在 UI 里稳定标识这一行
    var displayKey: String
}

enum EditValue: Sendable, Equatable {
    case null
    case text(String)          // 用户输入的文本（尚未转成字面量）
    case bytes([UInt8])        // BLOB 场景（从文件导入）
    case unchanged             // 仅用于「未修改」标记，不会进入 SQL
}
```

### 2.1 为什么 `RowIdentity` 要保存「原值」而不是「新值」

Commit 时 WHERE 必须匹配**修改前**的值：

```sql
-- 用户把 id 从 5 改成 6
UPDATE `db`.`t` SET `id` = 6 WHERE `id` = 5;
```

因此 `UpdateChange.rowIdentity` 在**第一次编辑该行时就被冻结**，后续再改这一行的其他列不会改变它。同一行的多个编辑合并进同一条 `UpdateChange.sets`。

### 2.2 合并规则

`PendingChangeStore` 用 `rowIdentity` 作为键维护索引：

| 已有 | 新操作 | 结果 |
| --- | --- | --- |
| 无 | update(row, colA) | 新增 UpdateChange |
| update(row, colA) | update(row, colB) | 合并 sets |
| update(row, colA) | update(row, colA) | 覆盖该列的 set |
| update(row, colA=新值) | 改回原值（colA） | 若 sets 变空 → 删除该 UpdateChange；行状态回到 clean |
| 无 | insert(row) | 新增 InsertChange |
| insert(row) | update(同一新行) | 合并进 InsertChange.values |
| insert(row) | delete(同一新行) | 直接删除 InsertChange（不产生任何 SQL） |
| 无 | delete(row) | 新增 DeleteChange |
| update(row) | delete(row) | 删除 UpdateChange，替换为 DeleteChange |
| delete(row) | 编辑该行 | 拒绝（已删除的行不可编辑），提示先撤销删除 |

行为：**同一行最多只有一条 pending change**（insert / update / delete 三选一）。

### 2.3 Store API

```swift
@MainActor
final class PendingChangeStore: ObservableObject {
    @Published private(set) var changes: [PendingChange] = []
    private var index: [RowIdentity: Int] = [:]

    var isEmpty: Bool
    var count: Int

    func upsertCell(row: RowIdentity, column: String, value: EditValue,
                    originalValue: MySQLValue?)
    func hasFieldChange(row: RowIdentity, column: String) -> Bool   // 字段栏与网格的橙色标记
    func rowState(_ row: RowIdentity) -> RowState                  // .clean / .dirty / .inserted / .deleted
    func insertRow(values: [String: EditValue])
    func deleteRow(row: RowIdentity)
    func revert(row: RowIdentity)                 // 撤销某一行的所有改动
    func discardAll()

    func statements(using literalizer: SQLValueLiteral) throws -> [String]
    func previewText(using literalizer: SQLValueLiteral) throws -> String
}
```

## 3. SQL 生成

### 3.1 INSERT

```sql
INSERT INTO `db`.`tbl` (`a`, `b`) VALUES (1, 'x');
```

- 只包含用户在新增行里**实际填过**的列；未填的列不出现，交给服务器默认值
- 如果用户没填任何列 → 生成 `` INSERT INTO `db`.`tbl` () VALUES (); ``（合法，插入全默认行）

### 3.2 UPDATE

```sql
UPDATE `db`.`tbl` SET `b` = 'y', `c` = NULL WHERE `id` = 5;
```

- `WHERE` 用 `RowIdentity.keys` 的全部键值，`AND` 连接；NULL 用 `IS NULL`
- `SET` 按列在表中的顺序输出（确定性，便于测试与 diff）

### 3.3 DELETE

```sql
DELETE FROM `db`.`tbl` WHERE `id` = 5;
```

### 3.4 语句顺序

为了保证外键约束下也能成功，顺序为：

1. 全部 `INSERT`
2. 全部 `UPDATE`
3. 全部 `DELETE`

（同类型内部按用户操作顺序。）这是简化策略（已登记为 `13-open-questions.md` 的 S1）：如果外键约束导致失败，事务会整体回滚，用户可以在事务里手动调整（或用 SQL 编辑器）。

### 3.5 字面量

所有值都经过 `SQLValueLiteral`（见 `03-mysql-layer.md` §4.2），**Preview 展示的字符串与实际下发的字节完全相同**。

## 4. Preview

`⌘⇧P` 打开一个 sheet：

```
┌─ 将要执行的 SQL（7 条）──────────────────────────────┐
│  1  INSERT INTO `app_dev`.`users` (`name`)           │
│     VALUES ('张三');                                  │
│  2  UPDATE `app_dev`.`users` SET `email`='a@b.c'     │
│     WHERE `id` = 42;                                  │
│  …                                                    │
├───────────────────────────────────────────────────────┤
│  [复制全部]  [在编辑器中打开]      [放弃]  [提交]      │
└───────────────────────────────────────────────────────┘
```

- 语法高亮（复用 `SQLLexer`）
- 「在编辑器中打开」→ 新建查询 tab 并填入这些 SQL（用户可以手动调整后再执行，此时不再走暂存）
- 数字标注语句序号，方便与网格里的行对应（悬停 SQL 高亮对应的网格行）

## 5. Commit

```
CommitCoordinator.commit(store, session, isReadOnly):
  1. store.isEmpty → 无操作
  2. connection.readOnly → 拒绝：「该连接为只读模式，无法提交」
  3. 再次校验所有行定位键非空（防止元数据过期导致 keys 为空）
  4. 向服务器下发：
       START TRANSACTION
       语句 1
       语句 2
       …
       COMMIT
     实现方式：把 START TRANSACTION / COMMIT 与语句一起作为**脚本**一次下发（走多语句），
               或逐条下发并在出错时发 ROLLBACK —— 采用后者，便于精确知道哪条失败。
  5. 逐条执行：
       成功 → 记录到 Console Log
       失败 → 立即 ROLLBACK（尽力执行），保留整个 store 不清空，弹出错误面板：
              ┌─ 提交失败 ────────────────────────────────┐
              │  第 3 条语句执行失败                        │
              │  [错误 1062] SQLSTATE 23000                │
              │  Duplicate entry 'a@b.c' for key 'uniq_email' │
              │                                            │
              │  UPDATE `app_dev`.`users` SET …            │
              │                                            │
              │  事务已回滚，所有修改都未生效。             │
              │  [放弃全部修改]  [关闭并修正]               │
              └────────────────────────────────────────────┘
  6. 全部成功 → 清空 store → 重新查询当前页
```

**细节规则**：
- 提交期间 UI 锁定（网格不可编辑），状态栏显示 `正在提交 3/7…`，可取消（取消 = 在下一个语句间发 ROLLBACK）
- 提交前后记录 `SELECT @@autocommit`；我们显式发 `START TRANSACTION`，结束后不改变会话的 autocommit 设置
- 若语句中含有 DDL（本设计不会产生，因为 DDL 只能从 SQL 编辑器走）→ 提前拒绝并提示「DDL 会隐式提交，请用 SQL 编辑器执行」
- Commit 超时用连接的 `queryTimeout`，超时后 `KILL QUERY` 并显示「提交超时，事务状态未知，请手动检查」

## 6. Discard

`⌘⇧⌫`：

- 弹确认（若改动 > 5 条，或含删除/插入）
- 清空 store → 重新查询当前页（不是简单地清脏标记，因为需要还原插入/删除的行）
- 单行撤销：右键行 → `撤销该行的修改`，只回退该行（从 store 移除 + 重绘该行）

## 7. 行定位与可编辑性判定

**关键决策**：无法唯一定位行的表（无主键且无唯一索引）**整表只读**，不做其它兜底。
用户视角的行为见 [`specs/04-data-editing.md`](../../specs/04-data-editing.md) §2。

打开表时（`MetaRepository` 提供）：

| 条件 | 可编辑性 |
| --- | --- |
| 有 PRIMARY KEY | `.editable(keys: pkColumns)` |
| 无 PK，但有 `UNIQUE` 索引且其列全部 `NOT NULL` | `.editable(keys: uniqueColumns)` |
| 无 PK，UNIQUE 索引可空 | `.readOnly(reason: "唯一索引列可为 NULL，无法可靠定位行")` |
| 无 PK 且无唯一索引 | `.readOnly(reason: "该表没有主键或唯一键，无法安全定位行")` |
| 视图 | `.readOnly(reason: "视图不可编辑")` |
| 连接只读 | `.readOnly(reason: "该连接处于只读模式")` |

只读时的 UI：
- 隐藏 `+ 行` 按钮，禁用删除
- 右侧字段栏照常显示字段与值，但所有编辑器禁用，栏顶写明原因
- 状态栏显示原因（不是简单变灰，要说明为什么）
- 双击单元格 → 直接打开 Quick Look（而不是跳到字段编辑器），这样仍能看到完整内容

**关于主键列本身被编辑**：允许（用户可能确实要改主键）。`RowIdentity` 用旧值，`SET` 里放新值。风险是可能违反唯一约束 → 由服务器报错并回滚，这是可接受的。

## 8. UI 元素

编辑入口只有一处：**右侧字段栏**（见 `14-row-inspector.md`）。字段栏里每改一个值就调用一次
`PendingChangeStore.upsertCell`，工具栏与状态栏只是它的只读投影。

工具栏左侧的 Action Control（只在数据网格 tab 激活时可用）：

```
[  ⟲ 放弃 ]  [  👁 预览 (7) ]  [  ✓ 提交 (7) ]
```

- 括号里是待提交的改动条数；为 0 时三个按钮都是禁用（50% 透明度）
- `提交` 按钮在只读连接上始终禁用，tooltip 说明原因
- Tab 标题右侧的 `●` 表示有未提交改动

状态栏左侧的橙色提示条：

```
● 有 7 处未提交的修改（3 新增 · 2 修改 · 2 删除）    [查看详情]
```

## 9. 边界情况

| 情况 | 处理 |
| --- | --- |
| 提交前表结构被外部改变（列被删） | 服务器报错 1054，展示错误，保留 store |
| 提交前行被外部删除 | `UPDATE`/`DELETE` 影响 0 行 → **视为成功**（幂等）；在 Console Log 记录 `affected 0` |
| 提交前行被外部修改 | `UPDATE` 会覆盖；这是预期行为。可选增强：在 Preview 里显示「该行可能已被他人修改」——**不做** |
| 大字段只加载了截断值，用户直接改了别的列 | 该列的 `SET` 不会被包含（只包含用户实际改过的列），所以不会把截断值写回去 —— **这是本设计的关键安全保证** |
| 用户编辑了大字段的截断值 | 先二次加载完整值 → 在其上应用修改 → 若完整值超过阈值则给出警告「该值较大（1.2 MB），提交时会有明显延迟」 |
| 同一字段被粘贴覆盖 / 反复修改 | 以最后一次为准 |
| 提交时连接已断开 | 尝试一次重连；重连失败则保留 store 并提示 |
| 事务中服务器崩溃 | 提示「事务状态未知」，建议手动检查数据；不清空 store |

## 10. 测试要点（`PendingChangeStoreTests`）

1. 同行多次编辑合并为一条 `UPDATE`，`WHERE` 用冻结的旧值
2. 改回原值 → 该 change 被移除，store 变空
3. 新增行 → 编辑 → 再删除 → 不产生任何语句
4. 删除行 → 编辑被拒
5. SQL 输出顺序为 INSERT → UPDATE → DELETE
6. 含引号 / 反斜杠 / 换行 / emoji / NULL / 空串的值，生成的 SQL 与 `SQLValueLiteral` 的期望输出一致
7. NULL 在 `WHERE` 中生成 `IS NULL`，在 `SET` 中生成 `= NULL`
8. 复合主键的行定位生成 `k1 = ? AND k2 = ?`
