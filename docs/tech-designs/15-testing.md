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
- 集成测试测必须打真库的东西：`MySQLSession`、`MetaRepository`、SQLite 仓库、Keychain 替身。
- 命名 `<被测类型>Tests`，一个被测类型一个文件。
- **不做 UI 自动化测试**：验收清单就是 `manual/` 的 14 页，人工过一遍（S22）。
- **不设覆盖率门槛**：覆盖率不驱动这个项目的决策。
- `make test` 必须一条命令跑完所有不需要真库的测试。

## 3. 可测试性注入点（决策记录）

需要外部世界的东西都收在一个协议后面，由 `AppEnvironment` 在启动时注入；**不引入 DI 框架**。

| 协议 | 不抽就测不了什么 |
| --- | --- |
| `Clock` | 空闲回收 5 分钟、元数据 TTL、草稿防抖 1s、查询超时、SSH 就绪轮询 |
| `CredentialStore` | Keychain 在单测与 CI 里不可用，必须有内存实现 |
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
  两者对应完全不同的修复。
- 夹具强制 `layoutSubtreeIfNeeded + displayIfNeeded` 会高估真实滚动成本，只用它做 A/B 对比，
  不用它下「是否 60 fps」的结论。

**进 CI 的方式**：毫秒断言会随机器和负载抖，**不进 CI**；要留回归就断言非抖指标
（操作次数 / 分配次数 / 集合大小），或标成手动 benchmark。

**产出**：探查代码用完即删，不提交；结论（数字 + 决策）回填 `07-data-grid.md` §10.1。

