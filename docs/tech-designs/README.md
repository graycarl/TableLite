# 技术设计索引

实现细节都放在这里。用户视角的需求见 [`../../specs/`](../../specs/README.md)。

| 文档 | 内容 |
| --- | --- |
| [01-architecture.md](01-architecture.md) | 分层、模块与目录、技术选型、并发模型、关键数据流、错误传播 |
| [02-persistence.md](02-persistence.md) | 连接配置、钥匙串、查询历史库、偏好、日志的存储方案与格式 |
| [03-mysql-layer.md](03-mysql-layer.md) | C 封装层 + Swift 封装层：接口、类型映射、多结果集、流式、取消、保活 |
| [04-ssh-tunnel.md](04-ssh-tunnel.md) | 基于系统 `ssh` 子进程的本地端口转发：命令拼装、认证、状态机 |
| [05-session-management.md](05-session-management.md) | 连接会话与多连接管理 |
| [06-ui-layer.md](06-ui-layer.md) | 视图模型、状态归属、SwiftUI 与 AppKit 的边界、标签状态 |
| [07-data-grid.md](07-data-grid.md) | 数据网格实现：表格配置、网格 SQL 生成、大字段两阶段加载、性能预算 |
| [08-pending-changes.md](08-pending-changes.md) | 变更暂存的模型、合并规则、SQL 生成、提交与回滚 |
| [09-filtering.md](09-filtering.md) | 过滤器到 SQL 的映射规则与测试要点 |
| [10-query-editor.md](10-query-editor.md) | 编辑器文本视图配置、语法扫描器、语句拆分、执行与结果模型 |
| [11-schema-and-import-export.md](11-schema-and-import-export.md) | 元数据读取、CSV 编解码、导出的流式实现 |
| [12-build-and-deps.md](12-build-and-deps.md) | XcodeGen、Homebrew 依赖、链接与 rpath、构建脚本 |
| [13-open-questions.md](13-open-questions.md) | 已知限制、刻意简化、待定事项 |
| [14-row-inspector.md](14-row-inspector.md) | 右侧字段栏：状态与数据流、字段编辑器映射、提交路径、大字段按需加载 |

## 与需求文档的对应

| 需求 | 技术设计 |
| --- | --- |
| [specs/01-connections.md](../../specs/01-connections.md) | 02、04、05 |
| [specs/02-workspace.md](../../specs/02-workspace.md) | 06 |
| [specs/03-data-browsing.md](../../specs/03-data-browsing.md) | 07、11、14 |
| [specs/04-data-editing.md](../../specs/04-data-editing.md) | 08、14 |
| [specs/05-filtering.md](../../specs/05-filtering.md) | 09 |
| [specs/06-query-editor.md](../../specs/06-query-editor.md) | 10 |
| [specs/07-schema-view.md](../../specs/07-schema-view.md) | 11 |
| [specs/08-import-export.md](../../specs/08-import-export.md) | 11 |
| [specs/09-readonly-mode.md](../../specs/09-readonly-mode.md) | 01、10 |
| [specs/10-ssh-tunnel.md](../../specs/10-ssh-tunnel.md) | 04 |
| [specs/11-preferences.md](../../specs/11-preferences.md) | 02 |

## 关键决策索引

这些结论不得轻易推翻，改动前先问用户。正文与理由在各文档里，本表只做定位。

| 决策 | 结论 | 位置 |
| --- | --- | --- |
| 数据库访问 | libmysqlclient（Homebrew `mysql-client`）+ 薄 C shim | [12](12-build-and-deps.md) §1 |
| 写入方式 | **不用 prepared statement**，生成 SQL 字面量下发 | [03](03-mysql-layer.md) §1 |
| 字符串 / 二进制转义 | 字符串走 `mysql_real_escape_string`；二进制走 `0x…` 十六进制字面量 | [03](03-mysql-layer.md) §4.2 |
| SSH 隧道 | 调系统 `/usr/bin/ssh` 做 `-L` 端口转发 | [04](04-ssh-tunnel.md) §1 |
| 数据网格 / 文本编辑器 | AppKit（`NSTableView` / `NSTextView`），其余用 SwiftUI | [06](06-ui-layer.md) §1、[07](07-data-grid.md) §1 |
| 工程组织 | XcodeGen，`TableLite.xcodeproj` 不进版本控制 | [12](12-build-and-deps.md) §1 |
| 第三方依赖 | 零 Swift Package 依赖 | [12](12-build-and-deps.md) §1、[13](13-open-questions.md) T10 |
| 变更暂存 | 每个标签独立；提交包在一个事务里 | [08](08-pending-changes.md) §1、§5 |
| 大数据列 | 默认只取前 4 KB，点开时再取完整值 | [07](07-data-grid.md) §3.1 |

「无主键表置为只读」这类**用户可感知的行为**由 `specs/` 定义（见 [`../../specs/04-data-editing.md`](../../specs/04-data-editing.md) §2），
实现侧的判定规则与文案见 [08-pending-changes.md](08-pending-changes.md) §7，不在这里重复。

## 约定

- 文档里的「必须 / 禁止」是硬性约束，实现时不得绕过；「建议」可权衡。
- 对应代码实现完成后，删掉已被代码取代的方案细节，**以代码为准**；但上表的关键决策不删。
- 涉及数据库写入的设计，默认选更安全的方案。
- 刻意简化的地方必须在 [13-open-questions.md](13-open-questions.md) 里登记。
