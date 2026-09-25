# AGENTS.md

本文件给在本仓库里工作的 AI Agent 使用。

## 项目是什么

`TableLite` —— macOS 原生的 MySQL 客户端，参考 TablePlus 但只保留高频功能。自用工具，不公证、不开沙箱；签名用本机自签名证书（只为让 Keychain 的「始终允许」授权跨构建有效，见 `docs/tech-designs/12-build-and-deps.md` §3.4）。最低 macOS 版本跟随构建机的 Homebrew（见 `docs/tech-designs/12-build-and-deps.md` §3.3）。

## 当前状态

当前处于产品完成初版实现的状态，基本功能已实现，还需要细节打磨。

## 文档地图（改动前必读）

| 位置 | 内容 | 规则 |
| --- | --- | --- |
| `specs/` | **需求设计**（面向用户）：界面、交互、行为边界、错误文案 | **只写用户能看到、能操作、能预期的东西**。禁止出现类名、函数签名、SQL 语句、库选型、文件路径、并发原语 |
| `docs/tech-designs/` | **技术设计**：架构、数据结构、接口、算法、存储格式、构建 | 实现细节都放这里 |
| `docs/roadmap.md` | 阶段划分、验收标准 | |
| `manual/` | **图形化使用说明书**：14 页静态 HTML，每个界面用内联 SVG 线框图画出 | 描述「用户看到什么」，与 `specs/` 同层。只写界面与操作，不写实现细节 |
| `README.md` | 对外说明 | |

**硬性规则**：

1. **所有改动都先改文档，文档定稿后再动代码**（不只是「需求变化」，细节打磨同样适用）。顺序：
   `specs/` → `manual/`（如需）→ `docs/tech-designs/` → 代码。需求 / 行为变化先改 `specs/`；
   界面表现变化（控件、位置、文案、快捷键）顺手同步 `manual/`；再评估 `docs/tech-designs/` 的连带影响。
   三者都改完、文档定稿后才动代码。改 `specs/` / `manual/` 前必须先拿到用户授权（见规则 7），
   未获授权时先报告差异和建议，不要擅自落笔。
2. 发现 `specs/` 里混进了实现细节，把它挪到 `docs/tech-designs/`；反之亦然。
3. 做出「刻意不做某事」或「有边界的简化」的决定时，**必须**登记到 `docs/tech-designs/13-open-questions.md`，否则算遗漏。
4. 文档里的「必须 / 禁止」是硬约束；「建议」可权衡。
5. 改动了 `specs/` 里任何**界面表现**的内容（控件、位置、文案、快捷键），**顺手同步 `manual/`**
   （`manual/` 本身的修改同样需要授权，见规则 7）。两者不一致时以 `specs/` 为准。
6. **开工前先定位文档**：接手任务后第一件事是判断它落在哪些 `specs/`、哪些 `manual/` 页面、
   哪些 `docs/tech-designs/` 文档的范围内，并在动手前把这份清单说出来。收尾时按同一份清单逐条自查：
   行为有没有违反 `specs/`、`manual/` 有没有和界面脱节、有没有推翻 `docs/tech-designs/` 里的关键决策。
7. **`specs/` 与 `manual/` 只能由用户拍板修改**：任务过程中**禁止**改需求文档和使用说明书
   （「顺手改个文案」也算）。发现它们与需求或实现不一致时，停下来把差异和建议报告给用户，
   获得明确同意后再改。与规则 1 冲突时以本条为准：改 `specs/` 之前先拿授权。
8. **`docs/tech-designs/` 保持精简，以代码为准**：设计阶段只写还没被代码定下来的部分；
   对应代码实现完成后，删掉已被代码取代的冗余细节（接口签名、字段清单、算法步骤、伪代码、
   逐条参数说明）——**代码是唯一事实来源**。但关键决策必须留下：写在对应文档的
   「关键决策 / 决策记录」小节里（如 `12-build-and-deps.md` §1、`07-data-grid.md` §3.1），
   并在 [`docs/tech-designs/README.md`](docs/tech-designs/README.md) 的「关键决策索引」里登记；
   代码注释可以引用这些决策锚点，但决策正文仍在文档里。收敛时只删方案细节，不删决策。

## 关键决策

关键决策的正文与理由不在本文件，统一放在 `docs/tech-designs/`：每篇文档里的「关键决策 / 决策记录」小节，
索引见 [`docs/tech-designs/README.md`](docs/tech-designs/README.md) §关键决策索引。

**改动任何一条关键决策前必须先问用户**，不要擅自推翻；有边界的简化仍按硬性规则 3 登记到
`docs/tech-designs/13-open-questions.md`。

## 容易踩的坑

只列跨文档、最容易犯的；各文档里已有原文的细节不在这里重复。

1. **`NSTextView` 的智能替换必须全部关掉**（智能引号、智能破折号、文本替换、拼写纠正）。不关的话 SQL 里的 `'` 会变成弯引号，字符串 `--` 会变成长破折号。见 `docs/tech-designs/10-query-editor.md` §2。
2. **`mysql_fetch_row` 返回的是可能含 `\0` 的字节串**，必须配合 `mysql_fetch_lengths` 取长度，禁止用 `strlen`；而且缓冲区会被下一次调用复用，一行数据必须在 C 回调返回前复制走。见 `docs/tech-designs/03-mysql-layer.md` §1。
3. **每个连接的所有 libmysqlclient 调用必须在同一条串行队列上**，连接句柄不是线程安全的。见 `docs/tech-designs/01-architecture.md` §3。
4. **大数据列的两阶段加载是安全保证**：网格里对超长列取的是 `LEFT(col, N)`，如果用户只改了别的列，绝不能把这个截断值写回数据库。见 `docs/tech-designs/08-pending-changes.md` §9。

## 命令

```sh
make deps      # 检查依赖 + 生成 Configs/Local.xcconfig
make gen       # xcodegen generate（改了 project.yml 或新增文件后必须跑）
make signing   # 建/导入本机自签名证书（新机器上一次性执行；见 tech-designs/12 §3.4）
make build
make run
make test
make smoke
```

**构建产物位置**：`make build` 用 `-derivedDataPath .build`，产物在
`.build/Build/Products/<Debug|Release>/TableLite.app`（`make run` 开的也是它）。
**不要**去 `~/Library/Developer/Xcode/DerivedData/` 下找 `TableLite.app` 来运行——
那是 Xcode 界面构建留下的旧产物，与当前代码不同步。手工测试用的 MySQL 用
`make db` 起（Docker，127.0.0.1:13307，root/tablelite，库 tablelite_dev）。

## 代码约定

- Swift 6 严格并发（`SWIFT_STRICT_CONCURRENCY = complete`）。不允许 `@unchecked Sendable`，除非是包装 C 指针且写清理由。
- UI 状态一律 `@MainActor`；`MySQLSession` 是 actor。
- 依赖方向严格向下：UI 层不得直接 `import CMySQLClient`，所有数据库访问经过 `MySQLSession` / `MetaRepository`。
- 纯逻辑（语句拆分、语法扫描、字面量生成、CSV 编解码、SSH 参数拼装）必须写成可单元测试的纯函数。
- 单元测试放在 `Tests/TableLiteTests/`，重点覆盖 `docs/tech-designs/` 里各文档的硬约束与边界情况。
- 界面文案统一用中文，SQL 关键字与类型名保持英文；术语表见 `specs/12-feedback.md` §8。
