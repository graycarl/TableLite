# 14 · 右侧字段栏（行详情栏）

表数据标签里**唯一**的编辑入口。数据网格只读，字段值的查看与修改都发生在这里。
需求见 [`specs/03-data-browsing.md`](../../specs/03-data-browsing.md) §7 与
[`specs/04-data-editing.md`](../../specs/04-data-editing.md) §3。

## 1. 技术选型

用 **SwiftUI** 实现，不进 AppKit：

- 字段数量通常是几十个，最多几百个；`LazyVStack` + `ScrollView` 足够，没有十万行的滚动压力
- 表单式布局（标签 + 编辑器 + 右侧按钮）用 SwiftUI 更省事
- 唯一的例外是**长文本 / JSON 的大窗口编辑器**：复用查询编辑器的 AppKit `NSTextView` 组件
  （需要行号、查找、以及强制关闭智能引号 / 替换，见 `10-query-editor.md` §2）

值编辑器直接使用 SwiftUI 控件：`TextField`、`TextEditor`、`DatePicker`、`Picker`、`Toggle`、
自绘的 `NullToggle` 按钮。不用 `Form`（它会引入系统默认的分组样式与间距），改用
`VStack` + 固定行高的自绘布局，保证与网格行高一致。

## 2. 状态与数据流

网格的「焦点单元格 / 选区」是唯一真源，字段栏是它的投影加编辑器。

```swift
@MainActor
final class TableTabViewModel: ObservableObject {
    @Published var rows: [DataGridRow] = []
    @Published var selection: Set<RowIdentity> = []    // 选中的行
    @Published var focusedCell: CellAddress?           // 焦点单元格（含 rowIdentity + columnIndex）
    @Published var inspectorVisible: Bool = prefs.showInspector
    let inspector: RowInspectorViewModel
}
```

- 字段栏展示的行 = `rows.first { $0.identity == focusedCell?.rowIdentity }`
- `selection.count > 1` → 不渲染字段列表，显示「请只选一行」
- `focusedCell == nil` → 空状态
- 切换行时，字段栏先清空草稿与错误，再触发大字段的按需加载

字段栏自身的状态：

```swift
@MainActor
final class RowInspectorViewModel: ObservableObject {
    @Published var fieldFilter: String = ""                 // 顶部搜索框
    @Published var focusedField: String?                    // 拿到键盘焦点的列名
    @Published var drafts: [String: FieldDraft] = [:]       // 列名 → 尚未提交的输入
    @Published var errors: [String: String] = [:]           // 列名 → 校验错误文案
    @Published var lastNonNull: [String: EditValue] = [:]   // 供 ∅ 按钮恢复
    @Published var loadingFields: Set<String> = []          // 正在二次加载的大字段
}
```

字段编辑器在「还没失焦」时值只存在于 `drafts`；失焦或按 `↩` 时才走提交路径（§4）。
`Esc` 丢掉草稿。

## 3. 字段编辑器映射

| 列类型 | 控件 |
| --- | --- |
| 普通文本 | `TextField`（单行） |
| 数字 | `TextField`，右对齐，`monospacedDigit` |
| 长文本 / JSON | `TextEditor`（内联，限高 4 行）+「展开」按钮 → AppKit `NSTextView` sheet（900×600） |
| 日期 / 时间 | `DatePicker` + 手输 `TextField`（时间戳 / datetime 用文本解析，避免时区歧义） |
| `ENUM` | `Picker`（下拉） |
| `SET` | 多选列表（checkbox 列表） |
| `TINYINT(1)`（偏好开启时） | 三态 `Toggle` |
| BLOB / 二进制 | 不可文本编辑：`查看` / `从文件导入…` / `∅ 设为 NULL` 三个按钮 + 大小与类型说明 |

- 主键字段的列名前加钥匙图标并加粗
- 类型文本只读，来自 `information_schema.COLUMNS.COLUMN_TYPE`（`07-data-grid.md` §3.2）
- BLOB 的「从文件导入」读取文件字节后作为 `EditValue.bytes` 写入暂存

## 4. 提交路径

```
编辑器 onSubmit / onFocusLost
  → RowInspectorViewModel.commit(column)
      · 值未变化            → 丢弃草稿，无操作
      · validate(column, rawInput)
            失败 → errors[column] = 文案；输入框抖动；保持草稿与编辑状态
      · 大字段尚未加载完整值且本次是「在截断值上编辑」
            → await loadFullValue(row, column)
      · TableTabViewModel.applyFieldEdit(rowIdentity, column, newValue)
             · PendingChangeStore.upsertCell(row:column:value:originalValue:)
             · row.state = .dirty
             · 网格 reloadRow(rowIdentity)（增量，不重新查询）
```

- 同一行的多次 `applyFieldEdit` 由 `PendingChangeStore` 合并成一条 `UpdateChange`
  （见 `08-pending-changes.md` §2.2）
- **只有用户实际编辑过的列才会进入 `UpdateChange.sets`**；被截断的大字段如果没被编辑，
  绝不会被写回数据库（`08-pending-changes.md` §9 的关键安全保证）
- 校验规则与类型映射：数字列只接受合法数字，日期列解析失败即报错，`SET` 值必须来自列定义

## 5. NULL 切换

- `∅` 按钮把字段置为 `EditValue.null`，并把切换前的值记进 `lastNonNull[column]`
- 再点一次恢复到 `lastNonNull[column]`；没有记录时恢复为空文本
- 值本来就是 NULL 时按钮呈按下状态
- 从 NULL 恢复不需要二次加载（NULL 没有「完整值」这回事）

## 6. 大字段的二次加载

选中单行且字段栏可见时，字段栏需要展示完整值：

```sql
SELECT `content`, `photo` FROM `app_dev`.`articles` WHERE `id` = 42
```

- 键集合来自 `RowIdentity.keys`（`08-pending-changes.md` §2），复合主键用 `AND` 连接
- 是否自动加载由 `LENGTH()` 别名（`content__len`）给出的字节数决定：
  - 合计 ≤ `inspector.autoLoadMaxBytes`（常量 8 MB）→ 选中行后自动加载
  - 合计 > 阈值 → 不自动加载，对应字段旁显示「加载完整内容…」按钮
- 结果写入 `DataGridRow.cellCache[columnIndex]`，与 Quick Look 共用同一份缓存
- 行无法定位（无主键 / 唯一键）→ 不发起查询，字段旁显示
  `无法定位行以加载完整内容`
- 查询返回 0 行（行已被删除）→ 显示 `该行已不存在，可能已被删除`
- 再次选中同一行时直接命中缓存，不重复查询；`⌘R` 刷新清空缓存

## 7. 与暂存区、网格的联动

- 字段栏不持有暂存数据，改动落进 `PendingChangeStore` 后由 store 反查渲染
- 字段的橙色标记 = `store.hasFieldChange(row, column)`
- 行状态（`.clean` / `.dirty` / `.inserted` / `.deleted`）由 store 派生，网格与字段栏共用同一份
- 新增行时字段栏切到「新增行」模式：所有字段为空，`applyFieldEdit` 改写 `InsertChange.values` 而不是 `UpdateChange.sets`
- 已删除的行：字段全部只读并变灰，栏顶显示「这一行已标记删除」与「撤销删除」

## 8. 宽度与持久化

- 宽度存 UserDefaults，键为 `inspector.width.<connectionID>.<schema>.<table>`（与列宽同一套前缀规则）
- 默认 320pt，范围 260–560pt；拖拽结束后写入
- 显示状态存全局偏好 `ui.showInspector`（默认 `true`）

## 9. 测试要点（`RowInspectorTests`）

1. 编辑后失焦写入暂存；`Esc` 不写入
2. 校验失败时不写暂存、保留草稿并给出错误
3. `∅` 在 NULL 与上一个非 NULL 值之间切换，生成的 SQL 为 `SET col = NULL`
4. 把字段改回原值后该行的 change 被移除
5. 多选 / 无选中时不渲染字段编辑器，显示对应空状态
6. 大字段合计超过 8 MB 时不自动加载；未加载的字段未被编辑时不进入 `SET`
7. 复合主键的二次加载生成 `k1 = … AND k2 = …`
8. 已删除行的字段为只读，编辑被拒绝
