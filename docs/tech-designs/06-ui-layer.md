# 06 · UI 层设计

## 1. SwiftUI 与 AppKit 的边界

| 部分 | 技术 |
| --- | --- |
| 窗口、菜单、工具栏、连接列表、主界面布局、右侧字段栏、对象树、标签栏、过滤器面板 | SwiftUI |
| 数据网格 | **AppKit `NSTableView`**（见 `07-data-grid.md` §1） |
| SQL 编辑器 | **AppKit `NSTextView`** |
| 快速查看面板 | AppKit `NSPanel` + SwiftUI 内容 |

**原则**：能用 SwiftUI 就用 SwiftUI；只有需要精细控制或性能的地方才下沉到 AppKit。所有跨边界的状态传递都通过 ViewModel + Coordinator，**不用通知中心**。

## 2. 状态归属

**每个状态都有唯一的归属者**，这是本层最重要的约定。

- `AppEnvironment` 在 App 启动时创建并注入，持有偏好、连接仓库、历史仓库、Console Log、`SessionManager`。
- `SessionManager` 是唯一可变根状态，持有 `[ConnectionSession]`。
- 每个标签的 ViewModel 由标签自己持有，标签关闭时释放。
- **规则**：视图只读状态、只发意图；没有全局单例；只有 `@MainActor` 类型可以持有 UI 状态。

## 3. 标签模型

- 标签种类：表数据 / 表结构 / 对象定义 / 查询 / 历史 / Console Log。
- **去重规则**：表数据、表结构、对象定义按 schema + 名称精确匹配复用；查询总是新建；历史与 Console Log 各只允许一个。
- **例外**：外键跳转即使目标表已打开也新建标签（过滤条件不同）。
- **关闭保护**：有未保存改动时弹「提交 / 放弃并关闭 / 取消」；App 退出走同一条路径。

## 4. AppKit 桥接约定

`NSViewRepresentable` 两端职责：SwiftUI View 只声明参数与回调；Coordinator 实现数据源 / 委托并把手势转成回调；NSView 子类纯渲染与交互。

**性能硬约束**：不要用 `updateNSView` 触发全量 `reloadData`，数据变化走增量路径：

- 页码 / 排序 / 过滤变化 → 全量 `reloadData`；
- 单字段编辑 → 只重绘该行相关单元格；
- 整行状态变化（新增 / 删除 / 撤销）→ 只重载该行。

行身份用 `NSTableViewDiffableDataSource` 的 item identifier，保证刷新后选中状态与滚动位置可恢复。网格与字段栏之间的桥接最简单：网格只回写「焦点单元格 / 选区」，字段栏是它的 SwiftUI 投影（`14-row-inspector.md` §2）。

## 5. 焦点与键盘

- 快捷键优先走 SwiftUI 的 `.keyboardShortcut` 与菜单 `Commands`，保证能出现在菜单里、能被用户发现。
- 网格与编辑器内部的按键由 AppKit 视图自己处理。
- 同一快捷键需要在网格 / 编辑器 / 面板上表现不同时（如 `⌘F`、`⌘I`），用 `@FocusedValue` 传递焦点上下文（`⌘I` 在过滤器面板里是「加一条条件」，在网格里是「插入新行」，见 `specs/05-filtering.md` §1）。

## 6. 线程与更新

- 所有 `@Published` 的写入都在 `@MainActor`；actor 的结果 `await` 回主线程后再写入。
- 流式结果**必须攒批**（约 200 行）再写入，避免逐行刷新。

## 7. 标签切换与性能

- 标签内容用 `ZStack` + `opacity` / `isHidden` 保持存活，**不要**用 `if` 切换，否则切回来会重建网格、丢滚动位置与选中状态。
- 标签多时只保活最近活跃的若干个（策略待定，见 `13-open-questions.md` T3）。
- 切换时把网格的滚动位置与选中状态快照进 ViewModel。

## 8. 界面语言（决策记录）

**界面文案硬编码中文**，不引入 `Localizable.strings` / `NSLocalizedString`。

- 术语表以 `specs/12-feedback.md` §8 为准；SQL 关键字与类型名保持英文。
- `Info.plist` 的 `CFBundleLocalizations` 只声明 `zh-Hans`，不声明没有资源支撑的 `en`。
- 将来要做多语言时再补资源文件，那是纯增量改动；现在为它付出的抽象成本不值得（S24）。
