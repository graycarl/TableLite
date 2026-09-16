# AGENTS.md

本文件给在本仓库里工作的 AI Agent 使用。

## 项目是什么

`TableLite` —— macOS 原生的 MySQL / MariaDB 客户端，参考 TablePlus 但只保留高频功能。自用工具，不签名、不公证、不开沙箱，最低 macOS 14。

## 文档地图（改动前必读）

| 位置 | 内容 | 规则 |
| --- | --- | --- |
| `specs/` | **需求设计**（面向用户）：界面、交互、行为边界、错误文案 | **只写用户能看到、能操作、能预期的东西**。禁止出现类名、函数签名、SQL 语句、库选型、文件路径、并发原语 |
| `docs/tech-designs/` | **技术设计**：架构、数据结构、接口、算法、存储格式、构建 | 实现细节都放这里 |
| `docs/roadmap.md` | 阶段划分、验收标准 | |
| `manual/` | **图形化使用说明书**：14 页静态 HTML，每个界面用内联 SVG 线框图画出 | 描述「用户看到什么」，与 `specs/` 同层。只写界面与操作，不写实现细节 |
| `README.md` | 对外说明 | |

**硬性规则**：

1. 需求变化 → 先改 `specs/`，再评估 `docs/tech-designs/` 的连带影响，两者都改完再动代码。
2. 发现 `specs/` 里混进了实现细节，把它挪到 `docs/tech-designs/`；反之亦然。
3. 做出「刻意不做某事」或「有边界的简化」的决定时，**必须**登记到 `docs/tech-designs/13-open-questions.md`，否则算遗漏。
4. 文档里的「必须 / 禁止」是硬约束；「建议」可权衡。
5. 改动了 `specs/` 里任何**界面表现**的内容（控件、位置、文案、快捷键），**顺手同步 `manual/`**。
   两者不一致时以 `specs/` 为准。

## 关键决策（不要擅自推翻）

| 决策 | 结论 | 理由位置 |
| --- | --- | --- |
| 数据库访问 | libmysqlclient（Homebrew `mysql-client`）+ 薄 C shim | `docs/tech-designs/12-build-and-deps.md` §1 |
| 写入方式 | **不用 prepared statement**，生成 SQL 字面量下发 | `docs/tech-designs/03-mysql-layer.md` §1 |
| 字形转义 | 字符串走 `mysql_real_escape_string`；二进制走 `0x…` 十六进制字面量 | 同上 §4.2 |
| SSH | 调系统 `/usr/bin/ssh` 做 `-L` 端口转发 | `docs/tech-designs/04-ssh-tunnel.md` §1 |
| 数据网格 / 文本编辑器 | AppKit（`NSTableView` / `NSTextView`），其余用 SwiftUI | `docs/tech-designs/06-ui-layer.md` §1 |
| 工程组织 | XcodeGen，`TableLite.xcodeproj` 不进版本控制 | `docs/tech-designs/12-build-and-deps.md` |
| 第三方依赖 | 零 Swift Package 依赖 | `docs/tech-designs/13-open-questions.md` T10 |
| 变更暂存 | 每个标签独立；提交包在一个事务里 | `docs/tech-designs/08-pending-changes.md` |
| 无主键表 | 置为只读 | `specs/04-data-editing.md` §2 |
| 大数据列 | 默认只取前 4 KB，点开时再取完整值 | `docs/tech-designs/07-data-grid.md` §3.1 |

## 容易踩的坑

1. **`NSTextView` 的智能替换必须全部关掉**（智能引号、智能破折号、文本替换、拼写纠正）。不关的话 SQL 里的 `'` 会变成弯引号，字符串 `--` 会变成长破折号。见 `docs/tech-designs/10-query-editor.md` §2。
2. **`mysql_fetch_row` 返回的是可能含 `\0` 的字节串**，必须配合 `mysql_fetch_lengths` 取长度，禁止用 `strlen`。
3. **每个连接的所有 libmysqlclient 调用必须在同一条串行队列上**，连接句柄不是线程安全的。见 `docs/tech-designs/01-architecture.md` §3。
4. **一行数据必须在 C 回调返回前复制走**，`mysql_fetch_row` 的缓冲会被复用。
5. **大数据列的两阶段加载是安全保证**：网格里对超长列取的是 `LEFT(col, N)`，如果用户只改了别的列，绝不能把这个截断值写回数据库。见 `docs/tech-designs/08-pending-changes.md` §9。
6. **`mysql-client` 是 keg-only**，头文件与库路径必须显式给出；`.app` 的 rpath 需要实测（`otool -L`）。见 `docs/tech-designs/12-build-and-deps.md` §3.1。
7. **退出 App 必须清理 ssh 子进程**，否则会残留。
8. **筛选条件的 `%` / `_` 必须转义**并显式加 `ESCAPE`。见 `docs/tech-designs/09-filtering.md` §1.4。
9. **`information_schema.TABLES.TABLE_ROWS` 对 InnoDB 只是估算**，界面必须标注「约」，且绝不在打开表时自动 `COUNT(*)`。
10. 界面文案统一用中文，SQL 关键字与类型名保持英文；术语表见 `specs/12-feedback.md` §8。

## 命令

```sh
make deps      # 检查依赖 + 生成 Configs/Local.xcconfig
make gen       # xcodegen generate（改了 project.yml 或新增文件后必须跑）
make build
make run
make test
make smoke
```

## 代码约定

- Swift 6 严格并发（`SWIFT_STRICT_CONCURRENCY = complete`）。不允许 `@unchecked Sendable`，除非是包装 C 指针且写清理由。
- UI 状态一律 `@MainActor`；`MySQLSession` 是 actor。
- 依赖方向严格向下：UI 层不得直接 `import CMySQLClient`，所有数据库访问经过 `MySQLSession` / `MetaRepository`。
- 纯逻辑（语句拆分、语法扫描、字面量生成、CSV 编解码、SSH 参数拼装）必须写成可单元测试的纯函数。
- 单元测试放在 `Tests/TableLiteTests/`，重点覆盖 `docs/tech-designs/` 里各文档「测试要点」小节列出的用例。
