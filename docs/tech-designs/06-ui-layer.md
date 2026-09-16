# 06 · UI 层设计

## 1. SwiftUI 与 AppKit 的边界

| 部分 | 技术 | 理由 |
| --- | --- | --- |
| 窗口、菜单、工具栏 | SwiftUI（`WindowGroup` + `Commands`） | 声明式足够，且与 SwiftUI 状态协同简单 |
| 连接列表、连接表单 | SwiftUI | 纯表单 |
| 主界面布局（分栏） | SwiftUI（`HSplitView` 或自绘） | 结构简单 |
| 右侧字段栏 | SwiftUI | 表单式布列 + 原生控件；只有长文本大窗口复用 AppKit `NSTextView` |
| 对象树 | SwiftUI `List`（`.sidebar` 样式） | 有内建的选择、折叠、搜索体验 |
| 标签栏 | SwiftUI 自绘 | SwiftUI 没有符合需求的标签栏组件 |
| 状态栏 | SwiftUI | |
| **数据网格** | **AppKit `NSTableView`**（`NSViewRepresentable`） | 见 `07-data-grid.md` §1；单元格只读，不承载编辑器 |
| **SQL 编辑器** | **AppKit `NSTextView`**（`NSViewRepresentable`） | 需要精确控制文本属性、行号、智能替换开关 |
| 快速查看面板 | AppKit `NSPanel` + SwiftUI 内容 | 需要独立浮动窗口与自由调整大小 |
| 过滤器面板 | SwiftUI | |

原则：**能用 SwiftUI 就用 SwiftUI；只有需要精细控制或性能的地方才下沉到 AppKit。** 所有跨边界的状态传递都通过 `ObservableObject` + `Coordinator`，不用通知中心。

## 2. 状态归属

这是本层最重要的约定：**每个状态都有唯一的归属者**。

```
AppEnvironment（@MainActor，全局唯一，注入到 EnvironmentObject）
├── preferences: PreferencesStore
├── connectionStore: ConnectionStore
├── historyStore: HistoryStore
├── consoleLog: ConsoleLogStore
└── sessionManager: SessionManager        ← 唯一的可变根状态

SessionManager
└── sessions: [ConnectionSession]         ← 每个连接一个
    ├── connection: Connection            （不可变快照）
    ├── state: SessionState
    ├── databases / selectedDatabase
    ├── meta: MetaRepository              （按库缓存的元数据）
    ├── mysql: MySQLSession?
    ├── tunnel: SSHTunnel?
    └── tabs: [WorkspaceTab]              ← 每个标签一个
        ├── id / title / kind
        └── viewModel: TabViewModel       （枚举，见 §3）
```

规则：

1. `SessionManager` 是唯一持有连接的地方；视图不直接持有 `MySQLSession`。
2. 标签的视图模型由标签自己持有，标签关闭时释放。
3. 视图只读状态、只发意图（`sessionManager.openTable(...)`、`tab.commit()`）。
4. 没有全局单例。`AppEnvironment` 在 `TableLiteApp` 里创建并注入。
5. 只有 `@MainActor` 的类型可以持有 UI 状态；`MySQLSession` 是 actor，不持有 UI 状态。

## 3. 标签模型

```swift
@MainActor
final class WorkspaceTab: Identifiable, ObservableObject {
    let id: UUID
    let kind: TabKind
    @Published var title: String
    @Published var hasUnsavedChanges: Bool     // 用于标题上的橙点
    let content: TabContentModel
}

enum TabKind: Hashable {
    case tableData(schema: String, table: String)
    case tableStructure(schema: String, table: String)
    case objectDefinition(kind: DatabaseObjectKind, schema: String, name: String)
    case query
    case history
    case consoleLog
}

enum TabContentModel {
    case tableData(TableTabViewModel)
    case tableStructure(SchemaTabViewModel)
    case objectDefinition(DefinitionTabViewModel)
    case query(QueryTabViewModel)
    case history(HistoryTabViewModel)
    case consoleLog(ConsoleLogTabViewModel)
}
```

### 去重规则

打开新标签前，按 `TabKind` 做一次**精确匹配**：

- 表数据：同 schema + 同表 → 复用
- 表结构：同上
- 对象定义：同 kind + schema + name → 复用
- 查询 / 历史 / Console Log：不匹配（查询总是新建；历史与 Console Log 各只允许一个）
- 外键跳转例外：外键跳转即使目标表已打开也新建标签（因为过滤条件不同）

### 关闭保护

```swift
func requestClose(_ tab: WorkspaceTab) {
    guard tab.hasUnsavedChanges else { close(tab); return }
    presentCloseConfirmation(tab)   // 提交 / 放弃并关闭 / 取消
}
```

App 退出时走同一条路径：`applicationShouldTerminate` 返回 `.terminateLater`，依次询问所有有未保存改动的标签，全部处理完再 `reply(toApplicationShouldTerminate:)`。

## 4. 各标签视图模型的接口

```swift
@MainActor
protocol TabViewModel: AnyObject {
    var displayTitle: String { get }
    var hasUnsavedChanges: Bool { get }
    func reload() async
    func prepareForClose() async -> CloseDecision      // .close / .cancel
}
```

### `TableTabViewModel`

```swift
@MainActor
final class TableTabViewModel: TabViewModel, ObservableObject {
    // 输入
    let sessionID: UUID
    let schema: String
    let table: String

    // 数据
    @Published var columns: [DataGridColumnModel] = []
    @Published var rows: [DataGridRow] = []
    @Published var selection: Set<RowIdentity> = []
    @Published var focusedCell: CellAddress?
    @Published var sort: [SortDescriptor] = []
    @Published var page = PageState()
    @Published var filter = FilterState()
    @Published var hiddenColumns: Set<String> = []
    @Published var isLoading = false
    @Published var loadError: MySQLError?

    // 右侧字段栏：网格的「焦点单元格 / 选区」是它的数据源（见 14-row-inspector.md）
    @Published var inspectorVisible: Bool = prefs.showInspector
    let inspector: RowInspectorViewModel

    // 元数据
    @Published var tableMeta: TableMetadata?     // 列定义 / 主键 / 唯一索引 / 大字段标记
    private(set) var editability: Editability

    // 暂存
    let pending: PendingChangeStore
}
```

## 5. AppKit 桥接约定

`NSViewRepresentable` 的两端职责：

| 角色 | 职责 |
| --- | --- |
| SwiftUI `View` | 声明式参数（列定义、行数据引用、只读开关、回调闭包） |
| `Coordinator` | 实现 `NSTableViewDataSource` / `Delegate`，持有 `NSTableView`；把用户操作转成回调；把数据变化映射成 `reloadData` / `reloadRow` |
| `NSView` 子类 | 纯渲染与交互 |

网格与字段栏之间的桥接最简单：字段栏不在 AppKit 里。网格只把 `focusedCell` / `selection`
回写给 `TableTabViewModel`，字段栏是它的 SwiftUI 投影（见 `14-row-inspector.md` §2）。

**性能约定**：不要用 `updateNSView` 触发全量 `reloadData`。数据变化走增量路径：

- 页码 / 排序 / 过滤变化 → 全量 `reloadData`
- 单字段编辑（字段栏里改值）→ 只重绘该行的相关单元格
- 整行状态变化（新增 / 删除 / 撤销）→ `reloadRow(indexes:)`
- 单元格值变化 → 只更新对应的 `NSTableCellView`

行身份用 `NSTableViewDiffableDataSource` 的 item identifier = `RowIdentity`，保证刷新后选中状态与滚动位置可恢复。

## 6. 焦点与键盘

- 键盘快捷键优先走 SwiftUI 的 `.keyboardShortcut` 与菜单 `Commands`，这样能出现在菜单里、也能被用户发现
- 网格与编辑器内部的按键（方向键、Tab、`↩`、`Esc`）由 AppKit 视图自己处理
- 需要在「网格有焦点」和「编辑器有焦点」之间区分的快捷键（例如 `⌘F` 在有焦点的网格上打开行过滤器，在编辑器里打开查找），用 `@FocusedValue` 传递当前焦点上下文

## 7. 线程与更新

- 所有 `@Published` 的写入都在 `@MainActor`
- actor（`MySQLSession`）的结果通过 `await` 回到 `@MainActor` 后写入
- 流式结果的消费：

```swift
task = Task { @MainActor in
    var buffer: [DataGridRow] = []
    for try await event in session.query(sql, mode: .unbuffered) {
        switch event {
        case .row(_, let values):
            buffer.append(DataGridRow(values: values, ...))
            if buffer.count >= 200 {            // 攒批，减少刷新次数
                rows.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        …
        }
    }
    if !buffer.isEmpty { rows.append(contentsOf: buffer) }
}
```

攒批是必须的：逐行 `@Published` 更新会让 SwiftUI 每行都刷新一次。

## 8. 标签切换与性能

- 标签内容用 `ZStack` + `opacity`/`isHidden` 保持存活，**不要**用 `if` 切换（否则切回来会重建网格、丢失滚动位置与选中状态）
- 标签数量多时只为「最近活跃的 5 个」保留视图，其余在切回时重建（重建成本低，因为数据在 view model 里）
- 标签切换时把网格的滚动位置与选中状态快照进 view model
