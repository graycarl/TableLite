# 07 · 数据网格

## 1. 为什么用 AppKit

SwiftUI 的 `Table` 不支持：十万行级的稳定滚动、冻结列、细粒度列宽持久化、右键菜单按单元格区分，以及精确控制「焦点单元格 / 选区」。因此数据网格用 `NSTableView`（view-based），通过 `NSViewRepresentable` 嵌入 SwiftUI。单元格本身**只读渲染**，不承载编辑器；编辑在右侧字段栏里（见 `14-row-inspector.md`）。

`NSTableView` 配置：

```swift
tableView.style = .plain                  // 不要 .inset，避免额外内边距
tableView.usesAlternatingRowBackgroundColors = prefs.grid.alternatingRows
tableView.allowsMultipleSelection = true
tableView.allowsColumnReordering = true
tableView.allowsColumnResizing = true
tableView.allowsEmptySelection = true
tableView.columnAutoresizingStyle = .noColumnAutoresizing
tableView.intercellSpacing = NSSize(width: 1, height: 1)
tableView.gridStyleMask = []
tableView.usesAutomaticRowHeights = false
tableView.rowHeight = prefs.grid.fontSize * 1.6      // 固定行高，不用自动行高（性能）
tableView.headerView = NSTableHeaderView()
```

数据源用 `NSTableViewDiffableDataSource`（macOS 11+）以获得稳定的行身份；行的 identity 使用「主键值构成的字符串」而非行号，这样刷新后选中状态能保持。

## 2. 列模型

```swift
@MainActor
final class DataGridColumnModel {
    let column: MySQLColumn          // 来自 libmysqlclient 的元数据
    let sourceColumn: SourceColumn?  // 若是 SELECT 投影，指向真实表列
    var width: CGFloat
    var displayTitle: String         // 表头：列名 + 类型提示（tooltip 里给完整类型）
}

struct SourceColumn {
    let name: String                 // 真实列名
    let isLargeProjected: Bool       // 是否是 LEFT() 投影出来的大字段
    let lengthAliasName: String?     // 配套的 LENGTH() 别名
    let fullLength: Int?             // 该单元格未被截断时的完整字节数
}
```

- 列的显示顺序 = 结果集列顺序
- 列宽：首次打开按内容估算（采样前 100 行 + 表头宽度，上限 400pt）；用户拖拽后按 `连接id + 库 + 表 + 列名` 持久化到 UserDefaults
- 列标题 tooltip：`` `col` TYPE(长度) NULL / PK / AUTO_INCREMENT ``

## 3. 表数据视图的 SQL 生成

### 3.1 大字段两阶段加载（关键设计）

BLOB/TEXT 列如果整列 `SELECT *` 拉回来，一个 5MB 的 BLOB 就能让一页 300 行变成 1.5GB。所以对「大字段」列做投影 + 按需二次加载：

**判定为大字段**：`type ∈ {TINYTEXT, TEXT, MEDIUMTEXT, LONGTEXT, TINYBLOB, BLOB, MEDIUMBLOB, LONGBLOB, JSON, GEOMETRY 系列}` 且偏好 `grid.lazyLargeColumns = true`（默认开）。

**生成 SQL**：

```sql
SELECT
  `id`,
  `name`,
  LEFT(`content`, 4096)  AS `content`,          -- 截断投影
  LENGTH(`content`)      AS `content__len`,     -- 附加长度列（用于展示「共 1.2 MB」）
  `created_at`
FROM `app_dev`.`articles`
WHERE <filter>
ORDER BY `id` ASC
LIMIT 300 OFFSET 0
```

- 附加的长度列**不显示为独立列**，由 `DataGridCoordinator` 消费后并入对应单元格的状态
- `content__len` 为 NULL 时说明原值为 NULL（不是空串）
- 排序一律用**真实列名**（`` `content` ``）而不是截断投影，避免按前缀排序
- 阈值 `4096` 可通过偏好调（`grid.largeColumnPreviewBytes`）

**二次加载**（选中该行且字段栏可见、打开 Quick Look、或开始编辑该字段时）：

```sql
SELECT `content` FROM `app_dev`.`articles` WHERE `id` = 42
```

- 必须能唯一定位行（即有主键/唯一键）；否则该单元格保持截断显示并提示「无法定位行以加载完整值」
- 二次加载的结果缓存在 `DataGridRow.cellCache[columnIndex]`，直到该 tab 关闭或 `⌘R` 刷新；字段栏与 Quick Look 共用这份缓存
- 若表没有大字段，则不生成任何 `LEFT()` 投影，等价于 `SELECT *` 的显式列版本

### 3.2 列清单

列清单来自 `information_schema.COLUMNS`（在 `MetaRepository` 中缓存），而不是 `SELECT * LIMIT 0`：
- 能拿到完整类型信息（`COLUMN_TYPE` 如 `tinyint(1)`、`enum('a','b')`）、注释、生成列标记
- 能拿到列的 `ORDINAL_POSITION` 保证顺序稳定
- 能识别不可见列（`EXTRA` 含 `INVISIBLE`）→ 默认不显示（可通过列过滤器打开）

### 3.3 ORDER BY 与分页稳定性

- 有主键：`ORDER BY <pk 列...> ASC`
- 无主键但有唯一索引（全列 NOT NULL）：`ORDER BY <唯一索引列...> ASC`
- 两者都没有：
  - 表格置为**只读**
  - 仍显示数据，但 `ORDER BY` 省略；状态栏提示「该表无主键，分页顺序不保证，且不可编辑」
- 用户点列头排序时：`ORDER BY <列> ASC` 追加主键作为次级排序键，保证稳定

### 3.4 行数估算

```sql
SELECT TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
```

- 显示为「约 12,480 行」
- `TABLE_ROWS` 为 NULL 或 0 且表非空时，状态栏显示「约 0 行（估算不可靠）」
- 状态栏提供「精确统计」按钮 → `SELECT COUNT(*) FROM db.tbl`（可能很慢，点击后变loading，可取消）
- **绝不在打开表时自动跑 `COUNT(*)`**

## 4. 单元格渲染

```swift
final class DataGridCellView: NSTableCellView {
    let textField: NSTextField      // 只读展示（isEditable = false），编辑在右侧字段栏
    var alignment: NSTextAlignment  // 数字右对齐
    var pendingState: PendingCellState
}
```

| 状态 | 外观 |
| --- | --- |
| 普通 | 系统文本色 |
| `NULL` | 灰色斜体 `NULL` |
| 已修改 | 橙色底色（alpha 0.15）+ 左上角小三角标记 |
| 新增行 | 整行绿色底色（alpha 0.10）+ 行号列显示 `+` |
| 已删除行 | 整行删除线 + 50% 透明度 + 红色底色 |
| 截断 | 文本后追加 `…`，tooltip 显示「原始长度 1.2 MB，按需加载」 |
| BLOB/二进制 | `«BLOB 12.3 KB»` / `0xDEADBEEF…` |
| 外键列 | 文本后追加 `↗` 图标；点击 `↗` → 在新 tab 打开被引用的表和行（`WHERE pk = 值`） |
| 焦点行 | 字段栏正在展示的那一行加一层淡色选中底色 |
| 主键列 | 表头加粗 + 加一个小钥匙图标 |
| 错误行（Commit 失败） | 红色底色 + 左侧感叹号，悬停显示服务器错误 |

行号列：固定在最左，宽 60pt，显示 1-based 行号；有 pending 状态时用图标替代数字。

## 5. 选择、焦点与字段栏

数据网格是**只读**的：不提供单元格编辑。所有值的修改都在右侧字段栏里做，
字段栏的实现见 `14-row-inspector.md`。网格这边只负责维护「焦点单元格 / 选区」，
并把它们同步给字段栏。

- 单击单元格 → 更新 `focusedCell`（行身份 + 列下标），字段栏切到该行并高亮对应字段
- 拖动 / `⇧` 点击 → 更新选中区域；`focusedCell` 取选区里最后落点的单元格
- 点行号 / `⌘` 点击行号 → 更新 `selection`；`selection.count > 1` 时字段栏不显示字段列表
- 方向键移动 `focusedCell`，字段栏跟随；字段栏也有焦点时用 `Tab` / `⇧Tab` 在字段间移动
- 双击单元格（可编辑的表）→ 展开字段栏并把键盘焦点交给对应字段的编辑器
- 双击单元格（不可编辑的表）→ 打开 Quick Look
- 网格里的键盘交互保持原样：`↑↓←→`、`⌘←/→`、`⌘↑/↓`、`⌘C`、`Space`

实现约定：选区变化后立即把 `focusedCell` 回写给 `TableTabViewModel`，
不要等到下一轮 runloop，否则字段栏会晚一帧。字段栏的编辑结果反过来只影响单元格的
「已修改」底色与行号标记，不回写选区。

## 6. 排序

```
点列头：无 → DESC → ASC → 无
       （TablePlus 的顺序是 DESC 优先，这里改为「无 → ASC → DESC → 无」，
        因为升序更常用；多列排序用 ⇧ 点击追加）
```

排序状态：

```swift
struct SortDescriptor: Hashable {
    let columnIndex: Int
    let columnName: String   // 真实列名
    let ascending: Bool
}
```

- 排序变化 → 重置到第 1 页并重新查询
- 表头显示 ▲/▼；多列排序显示序号
- 「无排序」= 按主键排序（§3.3）

## 7. 分页

```swift
struct PageState {
    var pageSize: Int = 300          // 可选 100 / 300 / 1000 / 5000 / 自定义
    var offset: Int = 0
    var estimatedTotal: Int?
    var exactTotal: Int?
    var isCountExact: Bool
}
```

- 底部控件：`[<] [>]  第 N 页  每页 [300 ▾]  跳到 [___]`
- 首次打开时用一个附加查询估算页数：`ceil(estimatedTotal / pageSize)`
- 深分页（`offset > 100_000`）时状态栏给出提示：「OFFSET 很大，翻页会变慢；建议用过滤器缩小范围」
- 分页查询与「是否有下一页」的判断：查询 `pageSize + 1` 行，多出的一行只用于判断 `hasNext`，不显示

## 8. 复制

| 菜单项 | 输出 |
| --- | --- |
| 复制单元格值 | 纯文本（BLOB 为 hex） |
| 复制行 | 制表符分隔的一行 |
| 复制选中行 | 制表符分隔的多行 |
| 复制整列的值 | 每行一个值 |
| 复制为 JSON | `[{"col": value, ...}, …]`，数字不加引号，NULL → `null` |
| 复制为 Markdown 表格 | 含表头与分隔线 |
| 复制为 CSV | 按偏好分隔符 |
| 复制为 CSV（含表头） | 同上 + 首行 |
| 复制为 SQL INSERT | `` INSERT INTO `db`.`tbl` (`a`,`b`) VALUES (…); `` |
| 复制列名 | 逗号分隔的列名 |
| 复制结构（DDL） | `SHOW CREATE TABLE` 结果（异步获取） |

- SQL INSERT 生成复用 `SQLValueLiteral`，保证与 Commit 的语句一致
- 复制 100 行以上时给一个轻提示「已复制 12,480 行（2.1 MB）」

## 9. Quick Look

触发：中键点击单元格 / 选中后 `Space` / 右键 `快速查看` / 外键列点 `↗` 是另一回事。

面板（`NSPanel`，可调整大小，`Esc` 关闭）：

| 内容类型 | 展示 |
| --- | --- |
| JSON | 格式化 + 折叠（自研简单折叠树，不做完整 JSON 编辑器） |
| 长文本 | 等宽字体 + 行号 + 查找 |
| 二进制 / BLOB | 头部 hex dump（前 64 KB）+ 文件类型提示 + 「导出为文件…」 |
| 图片（Magic number 识别 png/jpeg/gif/webp） | 直接显示图片 + 「导出为文件…」 |
| 日期 | 原文 + 解析后的本地时间（若时区信息可用） |

Quick Look 打开时若该单元格是大字段投影且未加载 → 先执行二次加载（loading 指示器）。

## 10. 表格视图的状态模型

```swift
@MainActor
final class TableTabViewModel: ObservableObject {
    let sessionID: UUID
    let schema: String
    let table: String

    @Published var columns: [DataGridColumnModel] = []
    @Published var rows: [DataGridRow] = []          // 当前页
    @Published var selection: Set<RowIdentity> = []
    @Published var focusedCell: CellAddress?
    @Published var sort: [SortDescriptor] = []
    @Published var page = PageState()
    @Published var filter = FilterState()
    @Published var visibleColumns: Set<Int>?         // nil = 全部
    @Published var isLoading = false
    @Published var loadError: MySQLError?
    @Published var payloadBytes: Int = 0             // 状态栏展示

    let pending: PendingChangeStore
    let editability: Editability                     // .editable(pk:) / .readOnly(reason:)
    let inspector: RowInspectorViewModel             // 右侧字段栏（见 14-row-inspector.md）
}

struct DataGridRow: Identifiable {
    let identity: RowIdentity       // 主键值拼成的稳定字符串
    var values: [MySQLValue]
    var state: RowState             // .clean / .dirty / .inserted / .deleted
    var cellCache: [Int: MySQLValue] // 大字段二次加载缓存
}
```

## 11. 性能预算

| 指标 | 目标 |
| --- | --- |
| 打开一张 100 万行的表（300 行/页） | < 500 ms |
| 滚动帧率（300 行） | 稳定 60 fps |
| 字段栏编辑到界面更新 | < 16 ms |
| 1000 行/页的内存占用 | < 20 MB（不含大字段） |
| 撤销/重做 | **不做**（网格内不实现 undo；提交前可用 Discard 整体回退） |

---

> 相关：变更暂存见 `08-pending-changes.md`，右侧字段栏见 `14-row-inspector.md`，过滤见 `09-filtering.md`，只读模式的需求见 [`specs/09-readonly-mode.md`](../../specs/09-readonly-mode.md)。
