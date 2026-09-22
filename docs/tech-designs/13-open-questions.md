# 13 · 已知限制与待定事项

本文件记录三类内容：

1. **刻意简化** —— 明确决定不做，不是遗漏
2. **已知限制** —— 做了但有边界，需要在使用时注意
3. **待定** —— 尚未决定，实现到那一步时再定

---

## 1. 刻意简化（已决定不做）

| # | 项 | 说明 |
| --- | --- | --- |
| S1 | 事务内语句不做依赖拓扑排序 | 提交顺序固定为 INSERT → UPDATE → DELETE。外键约束导致失败时整体回滚，用户自行调整 |
| S2 | 过滤器不支持嵌套括号分组 | 所有条件只能是 AND 或 OR 中的一种 |
| S3 | 过滤器的高级模式不做语法校验 | 只做「防呆」级别检查 |
| S4 | 列过滤不影响 SQL | 隐藏的列仍会被查询，只是不显示。实现简单，代价是被隐藏的大字段也会被投影查询 |
| S5 | 网格内不做撤销 / 重做 | 用「放弃全部改动」整体回退，或按行撤销 |
| S6 | 不检测并发修改 | 提交时直接覆盖，最后写入者生效 |
| S7 | 编辑器不做自动补全 / 格式化 / 多光标 / 分屏 | 见 `specs/00-scope.md` §2.2 |
| S8 | 不做表结构编辑 | DDL 只能手写 |
| S9 | 不支持 Excel / JSON 文件导入、除 CSV 以外的导出格式（JSON、SQL INSERT）、SQL dump 导入、备份恢复 | |
| S10 | 不做连接分组与连接文件的导入导出 | |
| S11 | 不做命令行 deeplink | |
| S12 | 只有单窗口 | 不能开第二个窗口 |
| S13 | 界面只有中文，语法配色跟随系统 | 不做主题与快捷键自定义 |
| S14 | 不做网格内的二维粘贴 | 网格只读，粘贴多行文本铺开没有明确的落点；需要批量改数据时用 SQL 编辑器 |
| S15 | 右侧字段栏只给工具栏按钮，不设快捷键 | 避免与网格 / 编辑器的快捷键冲突；视图菜单里有同一项 |
| S16 | 查询结果标签不显示右侧字段栏 | 结果集只读，而且没有可靠的行定位键，字段栏在那里没有编辑价值 |
| S17 | 不做 MySQL 函数 / 存储过程的浏览与定义查看 | 对象树只有表、视图两组；例程定义要看就在编辑器里跑 `SHOW CREATE PROCEDURE` / `SHOW CREATE FUNCTION` |
| S18 | 不做临时调字号 | 编辑器工具栏没有 `A− / A+`，`⌘=` / `⌘-` 也不绑给字号。字号只在偏好设置里改（编辑器与网格各一项），避免误触改变布局 |
| S19 | 首启不设欢迎 / 引导屏 | 零连接时显示的就是普通连接列表加一句「选择一个连接开始」，入口只有列表里的「新建连接」（`⌘N`）。见 `specs/01-connections.md` §7 |
| S20 | 不做「数据 / 结构」同标签切换 | 结构视图永远独立占一个标签，入口只有对象树右键 `打开结构`；数据视图状态栏里不再有 `结构` 按钮，表结构状态栏也没有 `刷新`（刷新走 `⌘R` 或「可能过期」提示条）。同一个表可以同时开着 `users` 与 `users · 结构` 两个标签 |
| S21 | 右侧字段栏宽度全局共用，不按表区分 | 与列宽（按表记住）不同：字段栏宽度只全局记忆一份，切换表时不重算。见 `specs/03-data-browsing.md` §7、`specs/11-preferences.md` §3 |
| S22 | 不做 UI 自动化测试 | 验收清单就是 `manual/` 的 14 页，人工过一遍；UI 测试的维护成本远超收益。见 `15-testing.md` §2 |
| S23 | 不做存储版本迁移框架 | 只做向前兼容读取（未知字段忽略、缺失字段取默认值）；破坏性变更时备份后重建。见 `02-persistence.md` §9 |
| S24 | 不做本地化资源 | 界面文案硬编码中文，不引入 `Localizable.strings`。见 `06-ui-layer.md` §8 |
| S25 | 不支持 MariaDB | 只支持 MySQL 8.0+；测试矩阵单档（`mysql:8.4`）。见 `15-testing.md` §1、`specs/00-scope.md` §2.2 |
| S26 | 不做依赖注入框架 | 手写协议 + `AppEnvironment` 注入；只抽 `Clock` / `CredentialStore` / `FileSystemLocator`。见 `15-testing.md` §3 |
| S27 | 不做时区处理 | 日期时间值原样读、原样写，不解析不换算，也不读 `@@session.time_zone`。见 `03-mysql-layer.md` §4.3 |
| S28 | LIKE 转义的 `ESCAPE` 子句按 `sql_mode` 适配 | `09-filtering.md` §1.4 的固定 `ESCAPE '\\'` 在 `NO_BACKSLASH_ESCAPES` 下非法；实现为默认 `ESCAPE '\\'`、该模式下 `ESCAPE '\'`。见 `Core/SQL/FilterSQLBuilder.swift` |
| S29 | 预览 SQL 与正式下发共用同一条生成路径 | 字面量转义走「连接转义器」（`mysql_real_escape_string` 语义）注入，纯函数转义只作兜底，避免 Preview 与实际提交不一致。见 `03-mysql-layer.md` §4.2、`Core/SQL/SQLValueLiteral.swift` |
| S30 | 语句分类从严 | `VALUES` / `TABLE` 语句归为 query 但不放进只读白名单（`specs/09-readonly-mode.md` §4 未列即不放行） |
| S31 | 删除连接先清 Keychain，失败则不删 JSON | `02-persistence.md` §3 只要求「连带删除」未定顺序；选择不留无人认领的密码，代价是 Keychain 异常时需重试删除。见 `Core/Store/ConnectionStore.swift` |
| S32 | SSH `BatchMode` 只用于 config/agent 认证 | `BatchMode=yes` 会禁用 `SSH_ASKPASS`，密码/私钥口令认证不能加。见 `Core/SSH/SSHCommand.swift` |
| S33 | 退出 App 不弹查询脚本保存确认 | 草稿已防抖落盘、重启可恢复；仅「关闭标签」弹保存确认。避免退出流程串联多个 sheet 死循环 |
| S34 | CSV 导入空字段默认视为 `NULL` | 与导出默认「空串表示 NULL」形成往返；改默认只动 `ImportOptions.emptyFieldIsNull` 一处 |
| S35 | 导入「事务模式」与「遇错继续」互斥 | 勾事务即全部成功或全部回滚，忽略 continueOnError；`TRUNCATE` 是 DDL 隐式提交，在事务外先执行 |

## 2. 已知限制

| # | 限制 | 影响 | 缓解 |
| --- | --- | --- | --- |
| L1 | 结果集消费没有严格背压 | 超大结果集（百万行以上）时内存会增长 | 依赖分页查询与「结果较大，可随时停止」提示。若实际使用中成为问题，改为有界缓冲 + 阻塞式 `on_row` |
| L2 | 从查询结果导出时，`LIMIT` 剥离失败则只导出本次实际返回的行 | 可能少导出 | 导出面板明确写出实际行数 |
| L3 | 只读模式是语句级拦截，不是权限控制 | 绕过路径存在（例如存储过程内部写数据 → 已通过禁止 `CALL` 缓解） | 建议只读连接配一个只有 `SELECT` 权限的数据库账号 |
| L4 | 没有主键的表不可编辑（即使有全部列 NOT NULL 的唯一索引也只读） | 这类表只能靠 SQL 编辑器改 | 在界面上明确说明原因；这是刻意简化：唯一索引不参与行定位判定 |
| L5 | 大字段延迟加载依赖行定位能力 | 无主键表的大字段无法加载完整值 | 界面提示「无法定位行以加载完整内容」 |
| L6 | SSH 密码认证依赖 `SSH_ASKPASS` 机制 | 极少数环境可能失败 | 错误面板展示 SSH 原始输出，建议改用私钥 |
| L7 | 不检测并自动重连（隧道或连接断开后） | 需要用户手动点「重新连接」 | 这是刻意选择，避免在用户不知情时反复重试 |
| L8 | 系统 SSH 首次连接自动接受新主机指纹 | 首次连接不做人工确认 | 指纹**变化**时会明确失败，属于可接受的折中 |
| L9 | 主键列被编辑时用旧值做定位 | 违反唯一约束时提交失败并回滚 | 属于正常错误路径 |
| L10 | `information_schema` 的 `TABLE_ROWS` 对 InnoDB 只是估算 | 行数可能明显偏差 | 标注「约」，提供「精确统计」按钮 |
| L11 | 深分页（`OFFSET` 很大）会变慢 | 翻页体验下降 | 状态栏提示改用过滤器 |
| L12 | 字段栏自动加载大字段的上限是 8 MB | 一行里的大字段合计超过该值时，不会自动取完整值 | 字段旁提供「加载完整内容…」按钮，点开才取 |
| L13 | `make dist` 的产物依赖目标机器的 Homebrew | 换一台机器要先 `brew install mysql-client` 等项目，否则启动即缺库 | 自用工具，接受；真要做到自包含就回到 `12-build-and-deps.md` §3.1 的内嵌 dylib 方案（T1 已否） |
| L14 | CI 不覆盖需要真库的路径 | 编译与单元测试有保障，冒烟与集成测试只在本地跑 | 合并前本地跑一次 `make smoke`。见 `15-testing.md` §5 |
| L15 | CSV 读入一次性全量解析 | 超大 CSV 导入时内存随行数增长 | P8 导入向导实现增量解析；导出侧已是流式（11 §3.1） |
| L16 | 纯文本复制（TSV 等）的 NULL 表示为文本 `NULL` | 与空串在粘贴后不可区分 | CSV 复制/导出走独立 `nullRepresentation`，不受影响 |
| L17 | 语句级错误的 `statement` 只带整批 SQL 前 200 字符 | 多语句执行时错误定位不到具体哪条 | C 回调只有 `result_index` 没有语句偏移；语句拆分在编辑器侧可做精确映射 |
| L18 | 连接转义器（`escape`）是同步的 | 正在执行大查询时调用转义会阻塞到查询结束 | Preview 生成避开查询执行窗口；查询串行执行本身是协议约束 |
| L19 | SSH 健康检查单次探测失败即判死 | 网络抖动可能误报隧道断开 | `04-ssh-tunnel.md` §6 未定失败阈值；误报后用户手动重连（L7 不自动重连） |
| ~~L20~~ | ~~偏好 `gridLazyLargeColumns` 未在 `specs/11` 列出~~ | **已解决（2026-09-22）**：用户拍板写入 `specs/11-preferences.md` §3「超长内容延迟加载」 | — |
| L21 | 左侧栏显隐与对象树分组折叠状态未持久化（**P11 已解决**：`WorkspaceStateStore` 新增 `sidebarVisible` / `collapsedObjectTreeGroups`） | 重启后恢复默认（侧栏显示、分组展开）；`specs/02` §5 要求记住，待 P11 补持久化 | 运行期内由 @State 记住；P11 加 PreferenceKey |
| L22 | 标签中键点击关闭未实现 | 可用 ⌘W / 关闭按钮 / 右键菜单替代 | SwiftUI 无中键事件，需 AppKit 事件监控，收益低 |
| L23 | 测试连接无实时分步进度、取消仅丢弃结果 | 等待时面板只转圈，拿到整份报告后渲染 ✓/✗；点取消后 Core 仍会把测试连接跑完再关 | 结果正确（不留痕），体验可接受；真取消需 Core 加中断点 |
| L24 | 网格行号列不冻结 | 横向滚动时行号随内容滚出视野 | `07-data-grid.md` §4 要求固定最左；冻结需双表滚动同步，风险高收益低 |
| L25 | 快速查看的 JSON 只 pretty-print、长文本无查找/行号 | 大 JSON 浏览不便 | 二进制 hex 与图片预览已做；按需再增强 |
| L26 | 外键列的 ↗ 跳转未实现 | 不能一键跳到引用行 | `specs/03` §1/§10 有该入口；元数据已备好（`foreignKeyColumns`），待补 |
| L27 | SQL INSERT 复制遇未加载的大字段会用截断值 | 复制出的 INSERT 语句数据不完整 | 复制结果附带警告提示（L27 已缓解）；写路径（复制行/编辑）先自动加载完整值 |
| ~~L28~~ | ~~日期时间编辑器是纯文本框，与 specs 不一致~~ | **已解决（2026-09-22）**：用户拍板改 `specs/04` §3 为「单行输入框，原样显示与编辑」，`manual/04` 图 4-2 已同步 | — |
| L29 | 字段栏长文本大窗口无行号与查找 | `14-row-inspector.md` §3 有该要求 | 查询编辑器组件（P7）落地后复用其文本视图再补 |
| L30 | 预览 SQL 无语法高亮、悬停不高亮网格行 | `specs/04` §9 要求高亮 | 等宽纯文本已保证内容一致（S29）；高亮待 P7 词法扫描接入 |
| L32 | 有未提交改动时改过滤器用非阻塞 toast | specs/05 §3「先提示」可作模态理解 | 与改排序行为一致；暂存区本身不受过滤影响 |
| L33 | 查询编辑器走缓冲执行，单条大查询结果不可中途停止/流式显示 | 「结果较大，可随时停止」对大结果集实际不可用 | 属 L1/T2 范畴；执行中可 KILL 取消，只是结果一次性到达 |
| L34 | CSV 导入把整个文件读进内存 | 超大 CSV 导入内存随行数增长 | 导出侧严格流式；导入流式化待后续（L15 同源） |
| L35 | 表结构的「建表语句」页无语法高亮（**P11 已解决**：复用 `SQLHighlightedText`） | 纯等宽文本 + 行号 + 复制 | `SQLHighlightedText` 组件现成（L30 已解决预览高亮），随时可接 |

## 3. 待定事项

| # | 事项 | 需要决定什么 | 何时决定 |
| --- | --- | --- | --- |
| T1 | rpath 处理方案 | 是补 `LD_RUNPATH_SEARCH_PATHS`，还是把 dylib 拷进 `.app` 并改写 install_name | Phase 0，用 `otool -L` 实测后定（见 `12-build-and-deps.md` §3.1） |
| T2 | 结果集背压是否要严格实现 | 见 L1 | 实际使用中发现内存问题时 |
| T3 | 标签存活策略 | 是全部保活，还是只保活最近 5 个 | Phase 3 实现标签容器时 |
| T4 | 多语句执行的「遇错继续」默认值 | 默认「遇错停止」，是否保持 | Phase 7 之后按使用感受调整 |
| T5 | 是否加「连接分组」 | 连接变多后是否需要 | 连接数超过 15 个时再说 |
| T6 | 是否加编辑器字体/字号之外的配色自定义 | | 使用一段时间后按需 |
| T8 | 是否把「导出」也做成可后台继续执行的任务队列 | 多个导出并行 | Phase 8 |
| T9 | 二进制 / 图片单元格是否支持直接编辑（例如替换图片文件） | 需求不明确 | 使用后按需 |
| T10 | 是否引入第三方 Swift Package（当前为零依赖） | 引入必须先在本文档登记理由 | 任何时候 |
| T12 | `ProcessRunner` / `PortAllocator` 要不要抽成协议、接口长什么样 | 抽早了只会猜错接口；隧道那套可控测试环境（sshd）也还没定 | P10 做 SSH 隧道时，见 `15-testing.md` §3 |

## 4. 变更记录

| 日期 | 变更 |
| --- | --- |
| — | 初始版本：从 TablePlus 功能盘点与三轮取舍讨论中提炼 |
| 2026-09-17 | 改为「网格只读 + 右侧字段栏编辑」：新增 `14-row-inspector.md`，新增 S14–S16 |
| 2026-09-17 | 对象树只保留表与视图，去掉函数 / 存储过程的浏览与定义查看，见 S17 |
| 2026-09-17 | 说明书用 GitHub Pages 发布（Actions 部署 `manual/`），见 `12-build-and-deps.md` §5.1 |
| 2026-09-17 | 去掉临时调字号（编辑器 `A− / A+` 与 `⌘=` / `⌘-`）；网格字号新增偏好设置项，见 S18 |
| 2026-09-18 | Console Log 落盘轮转定为「按天轮转、保留 7 天」（见 `specs/11-preferences.md` §7），删除待定项 T7 |
| 2026-09-18 | 首次启动定为「零连接时的普通连接列表 + 一句说明」，不设独立欢迎屏，见 S19（`specs/01-connections.md` §7 原写法与 `manual/01-connections.html` 不一致，已对齐） |
| 2026-09-18 | 去掉「数据 / 结构」同标签切换：结构视图只作为独立标签，见 S20（`specs/07-schema-view.md` §1/§5、`specs/02-workspace.md` §7、`manual/02`、`manual/07`） |
| 2026-09-19 | 右侧字段栏宽度改为全局记忆（不再按表），见 S21（`specs/02` §1、`specs/03` §7、`specs/11` §3、`manual/03`、`manual/04`、`manual/11`） |
| 2026-09-19 | 补齐「新增行」入口的定义：固定在网格底部的 `＋ 插入行` 行（原先只写了「状态栏的 `+ 行`」，但状态栏里没有这个按钮），见 `specs/03` §1、`specs/04` §2/§4、`manual/02`、`manual/03`、`manual/04` |
| 2026-09-19 | 只读模式的工具栏提示不再枚举白名单，改为「只读模式：写操作已被禁用」，白名单只留在 `specs/09-readonly-mode.md` §4 与 `docs/tech-designs/10-query-editor.md` §10 |
| 2026-09-21 | T1 定案：实测依赖全部指向 `/opt/homebrew/opt/<formula>/lib/…` 稳定符号链接，不改写 rpath、不内嵌 dylib（`12-build-and-deps.md` §3.1/§3.2）；T11 定案：部署目标改为跟随构建机系统版本（当前 macOS 27），不声称支持更低 macOS |
| 2026-09-21 | **去掉 MariaDB 支持，只做 MySQL**（`specs/00-scope.md` §1/§2.1/§2.2、`specs/README.md`、`manual/` 全站、`README.md`、`AGENTS.md`）；服务器版本范围定为 MySQL 8.0+，测试矩阵单档，见 S25 |
| 2026-09-21 | 补齐测试与工程决策：新增 `15-testing.md`（测试分层、可测试性注入点、CI）、存储版本与迁移（`02-persistence.md` §9）、界面文案硬编码中文（`06-ui-layer.md` §8）、时区零处理（`03-mysql-layer.md` §4.3）、分发 `make dist`（`12-build-and-deps.md` §4.1）；新增 S22–S27、L13、L14、T12 |
| 2026-09-22 | Core/Model + Core/SQL 落地（W1-T1）：登记 S28（LIKE ESCAPE 按 sql_mode 适配，修正 `09` §1.4 矛盾）、S29（Preview 与下发共用连接转义器）、S30（语句分类从严）、L15（CSV 读全量解析）、L16（TSV NULL 文本表示）；行定位键 `RowKeyValue` 携带 `fieldType`/`isBinary` 以生成正确字面量 |
| 2026-09-22 | Core/MySQL + Core/Store + Core/SSH 落地（W1-T2/T3/T4）：冒烟 7/7 通过；登记 S31（删连接 Keychain 顺序）、S32（SSH BatchMode 策略）、L17–L20；`session.json` schema 由 Core/Store 首定（`SessionStateFile`），W2 的 SessionManager 对接时可调整；SSH 别名模式下 `Connection.validationIssues()` 仍强制要求 `ssh.user`，待 W2 连接表单放宽 |
| 2026-09-22 | Core/Meta + Core/Session 落地（W2-T5）：MetaRepository（information_schema + TTL 缓存 + DDL 失效）、SessionManager/ConnectionSession/Tab/AppEnvironment；`MySQLSessionProtocol`/`SSHTunnelProtocol` 抽协议供测试替身（S26 手写协议）；SSH 别名模式校验已放宽（`Connection.validationIssues()` 不再强制 `ssh.user`/私钥）；保活用固定 30s 周期（未按连接各自间隔）；退出前的未提交确认待编辑 wave 补 |
| 2026-09-22 | Features/Connections + Features/Workspace 落地（W2-T6/T7）：菜单快捷键走 `Commands + @FocusedValue`（`WorkspaceActions`/`AppActions`，后续 wave 在 WorkspaceView 里把 nil 换成真实现，nil 自动禁用）；对象树用 SwiftUI LazyVStack 不下沉 AppKit；登记 L21–L23；窗口最小尺寸取 860×560（specs 未定）；ConnectionColor 的 SwiftUI 颜色映射有两处（`swatchColor`/`swiftUIColor`）待收敛 |
| 2026-09-22 | DataGrid 数据网格落地（W3-T8，P4）：NSTableView 桥接 + `GridCell` 区分首屏值/截断值/完整值/编辑中值（截断值不写回的安全闸门）；`SessionTab.content` 去掉 `@ObservationIgnored`（否则字段栏不重绘）；列重排禁用（`07` §2 列顺序=结果集顺序）；字段栏不设快捷键（S15）；登记 L24–L27 |
| 2026-09-22 | 编辑与提交落地（W3-T9，P5，M1 达成）：字段栏编辑器 + 暂存 + 预览==提交（S29）+ 事务提交/回滚保留暂存 + 关标签/断开/删除连接/退出四处确认；**修复两个真库才暴露的 bug**：`MySQLValueMapping` 把数值/时间列（charset 63）误判为二进制导致主键定位失效、提交路径忽略语句级错误导致唯一键冲突被当成功；冒烟新增 `--edit-smoke` 编辑链路 e2e（5/5）；登记 L28–L30；`⌘I`/`⌘D`/`⌫` 仅在网格焦点时生效 |
| 2026-09-22 | 过滤器落地（W3-T10，P6）：行过滤器 14 操作符/Raw 模式互斥/列过滤浮层/右键快速筛选/250ms 防抖快速过滤/WorkspaceStateStore 持久化；冒烟新增 `--filter-smoke`（8/8）；⌘F 改为上下文分派（表数据标签=过滤横条，否则=对象树搜索）；`FilterState` 持久化草稿态保证 Esc 后保留；登记 L31–L32；外键 ↗ 跳转仍未实现（L26） |
| 2026-09-22 | SQL 编辑器 + 导入导出 + 表结构落地（W4-T11/T12/T13，P7/P8/P9）：冒烟新增 `--query-smoke`（6/6）；L29（字段栏大窗口换 SQLTextView 带行号查找）与 L30（预览高亮）已解决；登记 S33–S35、L33–L35；⌘S 加入 File 菜单（与网格提交按上下文启用）；结构视图列页顶部多了行数估算（超出 specs/07，待用户拍板）；`GridRow` 与 SwiftUI 撞名处统一写 `SwiftUI.GridRow`；当前工具链已移除 `func f(): T` 旧语法，必须写 `-> T` |
| 2026-09-22 | 收尾（W4-T15，P11，M3 达成）：偏好设置面板 7 组全部落地并即时生效；只读模式补「关闭前确认」并写回连接配置；SSH 指纹变化单独高亮、隧道断开时心跳先探隧道再报「SSH 隧道已断开」；**L21**（侧栏显隐 / 对象树折叠持久化）与 **L35**（建表语句语法高亮）已解决；`ConnectionColor` 的 `swatchColor` / `swiftUIColor` 两处映射收敛为一处；表数据状态栏接入 `导出…`（`.filteredTable`，带过滤条件）；首次加载用骨架占位、翻页叠加加载遮罩；App 图标落地；README 更新为当前状态。Core/Session 有改动：`ConnectionSession.ping()` 先探隧道、`ConnectFailure.underlyingMessage` 的 MySQL 分支补 SQLSTATE 格式、`SessionManager` 保活周期改用偏好「心跳间隔」 |
| 2026-09-22 | 用户拍板收尾分歧：`specs/11` §3 补「超长内容延迟加载」（L20 关闭）；`specs/04` §3 日期时间编辑器改为单行文本框、`manual/04` 图 4-2 同步（L28 关闭）；跨列快速过滤框定为不必要功能，建清理 todo（L31 届时关闭）；`manual/01` 图 1-1 摘要按 `specs/01` §1 对齐为「经 ssh-主机」；结构视图列页顶部的行数估算已移除（超出 `specs/07`） |
| 2026-09-22 | 移除跨列快速过滤框（W3-T10 自加）：删掉 FilterBar 输入框、`FilterState.quickFilter`、防抖与 `quickFilterClause`/`combine` 组合逻辑及对应测试，冒烟第 8 项改为只验证条件叠加 + 列显隐；`FilterState` 旧持久化 JSON 里的 `quickFilter` 字段按向前兼容忽略；**⌘F 回归 `specs/05` §1**：表数据标签前台 = 开关行过滤器面板，否则聚焦对象树搜索；右键「按此列筛选 / 按此值筛选 / 排除此值」保留（`QuickFilterAction`）。L31 关闭 |

> 新增限制或简化时，必须同时在本文件登记并在对应需求文档里说明，避免「以为做了其实没做」。
