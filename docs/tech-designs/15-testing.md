# 15 · 测试与验证

对应 `AGENTS.md` 的「纯逻辑必须写成可单元测试的纯函数」。本文件只记决策，实现以代码为准。

## 1. 支持的服务器版本（决策记录）

**只支持 MySQL，保证范围是 MySQL 8.0 及以上。不支持 MariaDB。**

- 实测依据：7 项冒烟验证（`03-mysql-layer.md` §8）在 `mysql:8.4.11` 上全部通过，
  客户端是 Homebrew `mysql-client` 26.7.0 提供的 `libmysqlclient`（静态链接进 App，见 `12-build-and-deps.md` §3.1）。
- 默认认证插件 `caching_sha2_password` 已内建；老服务器的 `mysql_native_password` 走外部插件，见 `13-open-questions.md` L41。
- 低于 8.0 的版本不做兼容分支，失败按服务器原始错误展示（`03-mysql-layer.md` §7）。
- **测试矩阵只有一档**：`mysql:8.4`。要验别的版本就把 `MYSQL_HOST` 指向它，跑同一个脚本。

## 2. 测试分层

| 层 | 位置 | 依赖 | 何时跑 |
| --- | --- | --- | --- |
| 单元测试 | `Tests/TableLiteTests/Unit/` | 无 IO | 每次 `make test` |
| 集成测试 | `Tests/TableLiteTests/Integration/` | 真数据库 | `make test`，没给 `MYSQL_HOST` 就 `XCTSkip` |
| 冒烟 | `Sources/TableLite/Core/MySQL/SmokeRunner.swift` | 真数据库 | `make smoke` |

- 单元测试只测纯逻辑：语句拆分、词法扫描、字面量生成、CSV 编解码、SSH 参数拼装、
  暂存区合并规则、过滤器 SQL 生成 —— 也就是 `AGENTS.md` 要求写成纯函数的那些。
- 集成测试测必须打真库的东西：`MySQLSession`、`MetaRepository`、SQLite 仓库。
- 命名 `<被测类型>Tests`，一个被测类型一个文件。
- **不做 UI 自动化测试**：验收清单就是 `manual/` 的 14 页，人工过一遍（S22）。
- **不设覆盖率门槛**：覆盖率不驱动这个项目的决策。
- `make test` 必须一条命令跑完所有不需要真库的测试。

## 3. 可测试性注入点（决策记录）

需要外部世界的东西都收在一个协议后面，由 `AppEnvironment` 在启动时注入；**不引入 DI 框架**。

| 协议 | 不抽就测不了什么 |
| --- | --- |
| `Clock` | 空闲回收 5 分钟、元数据 TTL、草稿防抖 1s、查询超时、SSH 就绪轮询 |
| `CredentialStore` | 读写落盘，UI 与会话层不该直接碰文件系统；单测用内存实现 |
| `FileSystemLocator` | `Application Support` 路径、临时文件 + 原子替换、测试要指到临时目录 |

- 每个协议两份实现：`Live…`（真实）与 `InMemory…`（测试）。
- **暂缓**：`ProcessRunner` / `PortAllocator`（SSH 隧道用）留到 P10 再抽（T12）——
  现在抽只会猜错接口，而且隧道那套测试环境（可控 sshd）也还没定。
- 业务代码里**禁止**直接 `Date()` / `FileManager.default` / `SecItem*` / `Process`。

## 4. 依赖方向的自动校验

`01-architecture.md` §1 的「UI 层不得 `import CMySQLClient`」是硬约束，但编译器管不了。
用 `scripts/check-imports.sh` 做 grep 检查，挂在 `make test` 里，违规就失败。

## 5. CI（决策记录）

- 触发：`workflow_dispatch` + push 到 `main`。
- runner：**`xcode-27`**。这个镜像的基础系统就是 macOS 27，与部署目标一致
  （`12-build-and-deps.md` §3.3 的 T11 决策把部署目标定成了跟随构建机）。
  普通镜像（`macos-26` 及更早）装不下这个部署目标。
- 内容：`make deps` → `make build` → `make test`。
- **冒烟与集成测试不进 CI**：托管 macOS runner 没有 Docker，跑不了 `scripts/smoke/docker-compose.yml`；
  改用 brew 起 mysqld 会让 CI 的数据库和本地不是同一个东西，容易红且难排查。
  需要真库的验证以本地 `make smoke` 为准（L14）。
- `xcode-27` 目前是 preview 镜像，官方提示可能有排队问题。若 CI 变得很吵，先去掉这个 workflow。

## 6. 性能排查方法（决策记录）

**触发**：用户报告卡顿，或 `07-data-grid.md` §10 的性能预算不达标时按本节做；**不引入常驻性能测试**（原因见下）。

**隔离夹具**：用既有测试替身（`SessionTestSupport.makeHarness()` + `FakeMySQLSession` +
`FakeTableDataMetadataProvider`）灌合成数据，配**真实** `NSTableView` / `NSScrollView` / `NSWindow`，
程序化改 `clipView.bounds.origin` 模拟滚动。不依赖 Docker / 真库，秒级迭代。
骨架即本次用的 `measureScroll(coordinator:tableView:frames:)`：900×600 视口、120 帧、
`rowHeight` 取协调器的值；每帧后 `layoutSubtreeIfNeeded()` + `displayIfNeeded()`。

**度量三件套（缺一不可）**：

1. **扫参数看曲线**：固定其它变量，只改嫌疑参数（如列数 3 / 10 / 20 / 40），换算成
   「每帧」和「每可见单元格」成本。增长曲线是定位根因的第一信号；
   「per-cell 成本本身也随参数增长」直接指向单元格级的 O(n) 操作。
2. **`sample` 抓现场**：`sample <TestHost pid> 10`，看热点在 AppKit 的哪一层。
   本次由此发现 `NSButton.intrinsicContentSize` → SwiftUI `AttributeGraph`、`_setDefaultKeyViewLoop`，
   靠读代码几乎不可能猜到。
3. **微基准钉成本**：把候选原语单独循环 N 次计时（本次：`NSTextField` 30µs vs `NSButton` **1014µs**），
   把「疑似」变「铁证」。

**读数约定**：

- 报数字必须带夹具条件（行数 / 视口 / 帧数 / 步长 / 机器）。绝对毫秒受夹具影响，**结论看相对缩放**。
- 区分「新建单元格」与「复用 / 重配单元格」：步长大时放大前者，步长小才接近真实复用；
  两者对应完全不同的修复。反过来，**先用计数探针数清楚稳态下到底建了几个视图**比看采样更直接：
  2026-10 排查 `wide_test` 时，创建只在第一帧发生、之后 100% 命中复用，于是「新建成本」被整体排除，
  真因落在「常驻视图数量」上。
- **成本到底 ∝ 什么，取决于规模参数怎么扫**：宽表的成本不是 ∝ 可见单元，而是 ∝ 可见行 × **全部列**
  （`NSTableView` 没有水平虚拟化，见 `07-data-grid.md` §10.2）。扫参数必须把「列数」与「行数」分开扫，
  只扫行数会得出错误结论。
- **怀疑某个原因时，必须做一次「只关掉它」的反证实验**：2026-10 曾把「单元格用 Auto Layout 约束」当
  头号嫌疑，全改成手动 `frame` 后 p50 192.8 → 218 ms（无改善），当场推翻。没有这一步，就会去优化一个
  不存在的瓶颈。
- 夹具强制 `layoutSubtreeIfNeeded + displayIfNeeded` 会高估真实滚动成本，只用它做 A/B 对比，
  不用它下「是否 60 fps」的结论。

**进 CI 的方式**：毫秒断言会随机器和负载抖，**不进 CI**；要留回归就断言非抖指标
（操作次数 / 分配次数 / 集合大小），或标成手动 benchmark。

**产出**：探查代码用完即删，不提交；结论（数字 + 决策）回填 `07-data-grid.md` §10。

## 7. 测试 suite 的并发结构与运行成本（决策记录，2026-09-29）

**决策：测试 suite 的 `setUp` / `tearDown` 一律写成同步的 `setUpWithError()` / `tearDownWithError()`，
禁止写成 `async throws` 覆盖。**

- 现象：722 个用例里 536 个 < 5ms（中位 0.8ms），但 126 个 ≥ 100ms，且数值精确聚在 100 / 200 / 300ms
  整数量级上 —— 这 126 个占了用例总时长的 91%。慢的全是 `async` 用例，集中在同样几个 suite 上。
- 根因：**类上标 `@MainActor` 且存在 `async` 的 `setUp` / `tearDown` 覆盖**时，XCTest 给每个用例多算约
  100ms（每多一个 async 覆盖就多一份）。**与被测代码无关：空用例也照样慢。**
- 隔离对照（每档 20 个空用例，各跑 2 轮取区间）：

  | 结构 | 每用例 |
  | --- | --- |
  | `@MainActor` 类，无 async 覆盖 | ~4ms（偶发 100ms） |
  | `@MainActor` 类 + `async setUp()` | ~100ms |
  | `@MainActor` 类 + `async setUp()` + `async tearDown()` | ~180–220ms |
  | `@MainActor` 类 + 同步 `setUpWithError()` / `tearDownWithError()` | ~4ms |
  | 非 `@MainActor` 类 + 逐方法 `@MainActor` | ~4ms |

- 真实工作量的对照（`SessionTestSupport.makeHarness()` + 真 `connect()`）：121ms/用例 → 5.0ms/用例。
- 收益（macOS 27 / Mac Studio 10 核）：命中该陷阱的 8 个 suite 收敛后，用例总时长 18.4s → 5.2s，
  test session 25.7s → 11.9s，`make test` 端到端 39s → 24s。
- 配套：`FakeMySQLSession` 支持在 `init` 里预置应答，`SessionTestSupport.makeHarness()` 默认预置
  `successfulResponses()`，因此 `setUp` 里不再需要任何 `await`。
- 约束：**新增 suite 不得写 `async` 的 `setUp` / `tearDown`。** 需要在 setUp 里做异步准备时，
  改成构造期注入（替身预置应答 / 直接建好对象）或挪到用例首行。

## 8. 应用内滚动基准（决策记录，2026-10-08）

**问题**：帧级卡顿（CA commit 背压、WindowServer 交互、UpdateCycle 调度）只在真实 App 进程里出现，
§6 的隔离夹具测 CPU 成本够用，测不了帧级行为；而让真人滚动再配合采样，一轮验证要几分钟且无法自动化。

**决策：App 内置基准模式 + 三个脚本，让 Agent 一条命令完成「复现 → 测量 → 视觉自查」全链路。**

### 8.1 `--bench-scroll <table>`：应用内滚动基准

启动参数（与 `--filter-smoke` 等同族，但**不是无头模式**——要的就是真实窗口与渲染管线）：

```sh
MYSQL_PORT=13307 MYSQL_PASSWORD=tablelite MYSQL_DATABASE=tablelite_dev \
  TableLite.app/Contents/MacOS/TableLite --bench-scroll wide_test
```

- 行为：正常启动（真实 `AppEnvironment`）→ 自动连目标库（`MYSQL_*` 环境变量，同 §2 冒烟约定）
  → 打开指定表 → 等数据加载完成 → 把显示条数调大（退出前恢复偏好原值）
  → `CADisplayLink` 以固定速度驱动 `clipView.scroll(to:)` 往返滚动 → 记录逐帧间隔
  → 输出一行 JSON（帧数、p50/p90/p99/max、>34ms 帧数、滚动行程）到 stdout 并退出。
- **显示条数要在开表之前就调好**（2026-10-13 修）：原来先按偏好的条数加载一遍、再 `setRowLimit` 重载，
  而 `setRowLimit` 是异步起查询，调用后 `loadState` 还停在旧的 `.loaded`，按状态轮询会**立即返回**——
  于是第二次加载与测量窗口重叠，数字里混进一段主线程阻塞（表现为 p99 长尾，日志还会谎报「实际 1000 行」）。
  现在：① 先把 `preferences.rowLimit` 改成 `--bench-rows` 再开表，只加载一次；② 万一标签自带条数压过偏好，
  兜底走 `waitForReload()`——先等 `.loading` 再等 `.loaded`；任何提前返回路径都在 `defer` 里恢复偏好。
- **度量用帧间隔分布，不用 CPU 采样**：卡顿是帧级突发，主线程 20% 占用也可能 p99 到秒级
  （2026-10 排查 wide_test 卡顿的实测教训）。
- 数字只在**同机器、同表、同参数**下做 A/B 对比，不设绝对阈值、不进 CI（同 §6 读数约定）。
- 入口封装：`make bench`（Debug）/ `make bench CONFIG=Release`。

### 8.2 `scripts/dev/profile-scroll.sh`：一键卡顿录制

`--bench-scroll` 自驱动 + `xctrace record --template "Animation Hitches" --attach` 录制 →
导出 `hitches-frame-lifetimes` / `hitches` 两张表。**脚本必须清理 `$TMPDIR/instruments*.ktrace`**：
xctrace 的原始中间文件不会自动删除，一次录制能留 10GB+（2026-10-08 六个残留文件吃掉 69GB 磁盘）。

### 8.3 `scripts/dev/shot.sh`：窗口截图

**按 PID** 定位调试实例的窗口（`axctl window`，`kCGWindowOwnerPID` 过滤，取面积最大的窗口），
`screencapture -l` 抓图。Agent 读图即可自查视觉回归（字体、对齐、颜色、角标），不需要人工过目。
同名双实例下按 app 名找窗口会截错进程，所以不做。详见 §9.6。

### 8.4 边界

- 基建只服务**开发与排查**，不承诺捕获所有卡顿（触控板惯性滚动、多屏刷新率差异仍可能要人工复核）；
- 基准模式改动用户偏好后必须恢复；连接用完即断开，不写入连接列表与凭据文件；
- 性能修复的**决策与数字**仍回填 `07-data-grid.md` §10，本文件只定义工具。

## 9. Agent 自测基建：隔离实例、启动原语、AX 驱动（决策记录，2026-11-04）

**问题**：§6 / §8 解决的是「量得准」，但 agent 日常要做的是「看一眼某个界面 / 点一下某个按钮 / 看看报了什么错」。
现状只有几个写死的 smoke 模式，任何新状态都得真人点；截图能看不能动；脚本按 app 名找进程与窗口，双实例下会互相误伤。

**决策：给 agent 一套「隔离实例 + 启动原语 + AX 驱动 + 三源日志」的通路，调试通路只在 Debug 构建存在，不引入常驻服务。**

- 例外：`DevStateProbe`（等加载 / 定位网格）与 §8 的 `--bench-scroll` 共用，**Release 也编译**，
  但不被调用时没有任何行为；S50 的「只在 Debug」只约束 `--dev-*` 与 `DevLaunchRunner`/`DevLaunchOptions`。

### 9.1 隔离 profile（决策记录）

- 两个 Debug-only 启动参数：`--dev-data-dir <path>` 覆盖存储根（`AppStorageLayout`），
  `--dev-defaults-suite <id>` 把偏好与工作区状态切到独立 `UserDefaults` suite。
  **两者必须成组**：只给数据目录时自动补 `<主 bundle id>.dev`；`AppEnvironment.live` 只收到一半会抛错，
  suite 无法创建时也抛错，**不静默回落到标准域**。
- **硬约束：必须拒绝**指向真实根 `Application Support/TableLite`、它的任何祖先与后代、`$HOME` 及其祖先、
  系统根 `/`、空路径的 `--dev-data-dir`（展开 `~`、解析符号链接后再比较路径分量）；
  以及为空或等于主 bundle id 的 suite。调试实例绝不能写坏真实配置。
- 同一组校验在脚本侧（`scripts/dev/lib/profile.sh`）重新实现一次：`rm -rf` / `defaults delete` 在那一半。
- 种子由脚本直接写文件完成（`connections.json` / `credentials.json`，格式见 `02-persistence.md` §2/§3），
  并在 dev suite 里预置 `consoleLog.writeToFile = true`；`--dev-connect` 建立的临时连接不落盘、不写凭据。
- 窗口 frame 自动保存（`NSWindow.setFrameAutosaveName`）写的是 UserDefaults 标准域，**不受 suite 隔离**：
  调试 profile 下 autosave 名必须带 `-dev` 后缀。
- 已知可接受残留：AppKit 全局键（`NSNavLastRootDirectory` 等）与 `~/Library/Saved Application State/`（S51）。
- 默认路径 `.build/dev-data` + suite `com.graycarl.tablelite.dev`。`make clean` 只删 `.build`（数据目录没了、
  suite plist 还在）；要干净重来用 `tl.sh reset`——它同时清 dev suite 与标准域里的
  `NSWindow Frame TableLite.MainWindow-dev`（窗口 frame 自动保存那条，S51 的例外项）。

### 9.2 启动原语（决策记录）

原语只做「从内部才能干净做到」的事；用户能点到的交互一律走 AX 真实路径（9.4）。v1 原语：

| 原语 | 行为 |
| --- | --- |
| `--dev-connect <host>:<port>/<db>` | 用 `MYSQL_*` 环境变量取账号，建立临时连接（同 §8.1 约定） |
| `--dev-open-connection <name\|id>` | 从隔离 `connections.json` 取连接，密码读隔离 `credentials.json` |
| `--dev-open-table <db.table>` | 打开表数据标签并等加载完成 |
| `--dev-open-tab query\|history\|console\|structure\|definition` | 打开并选中对应标签 |
| `--dev-select-cell <row>,<column>` | 选中网格单元格；行 **1-based**，列只认**列名**，走 delegate 的真实选区路径 |
| `--dev-edit-cell <row>,<column>=<value>`（可重复） | 走字段栏的编辑 API 造未提交改动；值等于 `NULL`（大小写不敏感）表示置空。**无法表达字面量文本 `null`**（刻意简化，需要时改用 AX 在字段栏里输入） |
| `--dev-appearance light\|dark\|system` | 写隔离偏好并套到 `NSApp` |
| `--dev-window-size <w>x<h>` | 固定窗口尺寸（截图可对比的前提） |
| `--dev-row-limit <n>` | 显示条数 |
| `--dev-scenario <name>` | 具名场景注册表（9.3，v1 空）；名字在解析阶段就校验 |
| `--dev-ready-file <path>` | 原子写 ready JSON（同时 stdout 一行） |

**执行语义（硬约束）**

- 固定顺序：等窗口 → 外观 → 窗口尺寸 → 显示条数（先写偏好，ViewModel 初始化时读）→ 连接 →
  打开标签/表 → 选格 → 造改动 → 场景 → ready。
  `--dev-open-table` 用 `forceNew: false`：还原的标签现场（过滤 / 排序 / 列宽 / 显示条数）会一起回来，
  这是真实行为，脚本不能假设初始状态；显示条数被标签现场压掉时会补一次重载（同 §8.1 的做法）。
- 超时：窗口 15s；标签内容装配 15s；表加载 / 重载 30s。任何一步失败（含 `--dev-edit-cell` 没产生改动）
  → stdout 输出 `{"ready":false,…}` 并 `exit 1`；ready 文件写失败同样算失败。
- 与 `--bench-scroll` / `--*-smoke` **互斥**：两者都会往 stdout 打 JSON 并退出，组合使用直接报错。
- **ready 契约**（脚本据此判断「可以截图 / 可以点」，不用 sleep 猜；键名以 `DevLaunchRunner.stateSnapshot` 为准）：
  `{"ready":true,"pid":…,"data_dir":…,"defaults_suite":…,"is_dev_profile":…,"window":{"id":…,"frame":{…}},
  "state":{"connection":…,"database":…,"tabs":[…],"tab":…,"tab_kind":…,"table":…,"rows":…,"row_limit":…,
  "pending":…,"selected_rows":…,"focused_column":…,"columns":[…],"load_state":…},"warnings":[…]}`。
  `state.rows` 是**已加载数据行**（不含新增行），`--dev-select-cell` 的行号按网格行（含新增行）算。
- 原语只调用现有公开 API（`SessionManager` / `ConnectionSession` / `TableDataViewModel`），不绕过产品逻辑。
  原语失败多半意味着产品 bug，**禁止**为了让调试通过而在原语里加特例。

### 9.3 具名场景（决策记录）

机制保留（名字 + `@MainActor` 闭包 + 注册表），**v1 不预置任何场景**。

- 理由：原语 + AX 已覆盖盘点过的状态；预置场景会重复实现，并慢慢长成第二套 UI 测试（与 S22 冲突）。
- 只有「原语表达不了、AX 也到不了」时才加，一个场景 ≤ 10 行，并写清为什么不能拆成原语。

### 9.4 AX 驱动 `axctl`（决策记录）

自写 Swift CLI（`scripts/dev/axctl.swift`，`swiftc` 编译缓存到 `.build/tools/`），JSON 输出；**一律按 PID 定位**，禁止按 app 名。

- 能力：`doctor`、`window`（按面积返回主窗口优先）、`activate`、`terminate`、`dump`（默认剪枝）、
  `find`（id / role / title / desc + `--within` + `--nth`；**必须给选择器**）、`attributes` / `attr`、
  `click`（默认 AXPress，`--coords` 走坐标）、`press`、`set-value` / `type`（默认写 `AXValue`，
  `--keys` 走真实键盘）、`key`、`cell <row>,<col>`（行 1-based、列名或 **0-based AX 列序号**）、
  `wait`（单进程轮询）。**失败一律非 0 退出**，脚本用退出码判断成败。
- 实测踩过的两条坑，已固化在工具里：
  - **先聚焦再写 `AXValue`**：SwiftUI `TextField` 不在焦点上时，直接写 `AXValue` 不会进入 Binding，
    随后点「应用」读到旧草稿。`type` 与 `set-value` 都先设 `AXFocused` 再写值。
  - **带修饰键的快捷键走全局事件**：`CGEventPostToPid` 命不中 SwiftUI 的 key equivalent（`⌘↩` 不执行），
    改为先用 `AXFrontmost` 按 PID 激活，再 `CGEventPost` 到 HID；`NSRunningApplication.activate`
    在同名双实例下可能激活错进程，不用它。
- 硬约束：
  - **必须剪枝**：`wide_test` 实测整树约 20 万节点、遍历 8.5s 都走不完；`AXTable` 默认只给行列摘要。
  - **网格必须按 (row, column) 寻址**：AX 已给出 `AXRowIndexRange` / `AXColumnIndexRange` / `AXPosition` / `AXSize`，
    不需要逐格 identifier。
  - **wait 必须在同一个进程内轮询**，不要脚本层 sleep 循环（每次调用都要重建 AX 连接）。
- 输入合成走 CGEvent；文本优先 `AXValue`，中文回退到剪贴板 + `⌘V`。
- 环境前提：调用方进程有「辅助功能」权限（一次性授权），`tl.sh doctor` 自检。

### 9.5 identifier 规范

见 `06-ui-layer.md` §11。要点：静态控件才标；数据驱动元素用容器 + 标题/索引；identifier 不塞数据。

### 9.6 截图与日志（决策记录）

- 截图仍用 `screencapture -l<window id>`（真实像素，含窗口装饰）：`tl.sh shot [path] [--width 像素]`
  （`shot.sh` 是它的薄壳）**按 PID** 取窗口；确定性由 9.2 的 `--dev-appearance` / `--dev-window-size` 保证
  （不做应用内离屏截图，S47）。
- 日志三源，`tl.sh logs [--since 2m] [--grep 正则]` 合并输出：
  1. `run.log`（app stdout：原语轨迹 + ready JSON）；
  2. 隔离目录下的 `ConsoleLogs/*.log`（SQL 与服务器错误，靠 9.1 预置落盘）；
  3. `log show --info --debug --predicate 'subsystem == "com.graycarl.tablelite"'`（`StoreLog`）。
- **不新增统一日志 sink**（S52）：UI 症状（布局、文案、错位）用截图 + AX 判断，不指望日志。

### 9.7 统一入口与自检（决策记录）

- 单一入口 `scripts/dev/tl.sh`：`run` / `reset` / `quit` / `shot` / `ax` / `cell` / `logs` / `doctor` / `selftest` / `help`；
  实现放 `scripts/dev/lib/`；Make 只留人类别名 `make dev` / `make dev-reset` / `make dev-selftest`。
- **进程安全（硬约束）**：调试实例与真实实例 bundle id 相同，禁止 `pkill -x TableLite` 与 `osascript tell application id`；
  退出只能按 PID：`NSRunningApplication(processIdentifier:).terminate()`（Apple Event，走真实退出流程）→ `SIGTERM` → `SIGKILL`。
- PID 会被系统复用，所以 `app.pid` 必须做**身份校验**（`ps` 的 command 同时包含产物路径与 `--dev-data-dir`），
  不匹配就当 stale 删掉；`reset` 前后还要校验目标路径不是真实数据区。
- `selftest` 断言三个代表性状态的关键 identifier 与 `cell r,c` 可用，并用「筛选后读回单元格」验证
  交互真的改到了状态（不只是点到了按钮）。identifier 失效必须变红，否则工具会退化成猜坐标而无人察觉。
  前置条件是 dev MySQL 可达；收尾会退出调试实例（截图留在 `/tmp/tablelite-selftest-*.png`）。

### 9.7.1 常用命令（agent 视角）

```sh
tl.sh reset
tl.sh run --dev-open-connection demo --dev-open-table tablelite_dev.orders \
          --dev-select-cell 2,status --dev-window-size 1280x800 --dev-appearance light
tl.sh shot /tmp/a.png --width 1600
tl.sh ax click --id grid.statusbar.filter
tl.sh ax type  --id filter.raw-input --text "status = 'refunded'"
tl.sh ax click --id filter.apply
tl.sh cell 2,status
tl.sh ax key --combo cmd+return
tl.sh logs --since 2m --grep ERROR
tl.sh quit
```

### 9.8 实测数字（2026-11-04，Mac Studio / macOS 27）

- `tl.sh run --dev-open-connection demo --dev-open-table …` 到 ready：**约 1.3s**（含连库 + 读 300 行）。
- 单次 `axctl` 调用：**约 0.1s**（含进程启动）；`dump` 深树受剪枝控制，网格整树仍不可遍历（§9.4）。
- 增量 `make build`：约 25s。`axctl` 首次编译约 4s，之后源码不变不重编。

### 9.9 边界

- 调试通路只在 Debug 构建存在：`#if DEBUG`，Release 不解析任何 `--dev-*`（S50）。
- 不承诺覆盖「加载中 / 元数据失败」这类只能靠制造服务器故障达到的态；需要时先加原语。
- 权限（辅助功能 / 屏幕录制）是环境前提，不写进构建。
- 本文件只定工具与决策；实现细节以 `Sources/TableLite/Debug/` 与 `scripts/dev/` 为准。

