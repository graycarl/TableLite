# 技术设计索引

实现细节都放在这里。用户视角的需求见 [`../../specs/`](../../specs/README.md)。

本目录**只记录决策**：关键决策、理由、硬约束与刻意简化。已被代码定下来的实现细节不在这里重复，以代码为准。

| 文档 | 内容 |
| --- | --- |
| [01-architecture.md](01-architecture.md) | 分层与依赖方向、模块划分、并发模型、错误传播、沙箱与签名 |
| [02-persistence.md](02-persistence.md) | 连接配置、Keychain、查询历史、Console Log、偏好、日志的存储决策与硬约束 |
| [03-mysql-layer.md](03-mysql-layer.md) | C shim 边界与 Swift 封装：设计原则、类型映射与字面量生成、取消与超时、保活、错误映射 |
| [04-ssh-tunnel.md](04-ssh-tunnel.md) | 基于系统 `ssh` 子进程的本地端口转发：方案取舍、命令拼装、认证、生命周期 |
| [05-session-management.md](05-session-management.md) | 连接会话与多连接管理：作用域、连接流程、空闲回收、重连、标签现场还原 |
| [06-ui-layer.md](06-ui-layer.md) | SwiftUI 与 AppKit 的边界、状态归属、标签模型、桥接与刷新约定 |
| [07-data-grid.md](07-data-grid.md) | 网格实现决策：为何用 AppKit、大字段两阶段加载、顺序稳定性、显示条数限制、行数估算、性能预算 |
| [08-pending-changes.md](08-pending-changes.md) | 暂存的作用域、合并规则、SQL 生成、提交与回滚、可编辑性判定 |
| [09-filtering.md](09-filtering.md) | 过滤器到 SQL 的映射决策与交互约束 |
| [10-query-editor.md](10-query-editor.md) | 编辑器文本视图、语法高亮、语句拆分、执行、只读拦截 |
| [11-schema-and-import-export.md](11-schema-and-import-export.md) | 元数据读取与缓存、CSV 编解码、流式导出、导入 |
| [12-build-and-deps.md](12-build-and-deps.md) | 技术选型、Homebrew 依赖、链接与 rpath 风险、版本控制、Phase 0 |
| [13-open-questions.md](13-open-questions.md) | 已知限制、刻意简化、待定事项 |
| [14-row-inspector.md](14-row-inspector.md) | 右侧字段栏：技术选型、提交路径、大字段按需加载与暂存联动 |
| [15-testing.md](15-testing.md) | 支持的服务器版本、测试分层、可测试性注入点、依赖方向校验、CI |

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
| 支持的数据库 | 只支持 MySQL 8.0+，不支持 MariaDB | [15](15-testing.md) §1 |
| 依赖链接方式 | 直接用 Homebrew 的 `/opt/homebrew/opt/<formula>/lib/…` 路径；不改写 rpath，不把 dylib 内嵌进 `.app` | [12](12-build-and-deps.md) §3.1 |
| 部署目标 | 与构建机系统版本一致（当前 27.0），不声称支持更低 macOS —— 依赖 bottle 的 `minos` 无法降低 | [12](12-build-and-deps.md) §3.3 |
| 写入方式 | **不用 prepared statement**，生成 SQL 字面量下发 | [03](03-mysql-layer.md) §1 |
| 字符串 / 二进制转义 | 字符串走 `mysql_real_escape_string`；二进制走 `0x…` 十六进制字面量 | [03](03-mysql-layer.md) §4.2 |
| 并发模型 | 每个连接一条专用串行队列，所有 libmysqlclient 调用都在其上；`MySQLSession` 是 actor | [01](01-architecture.md) §3 |
| SSH 隧道 | 调系统 `/usr/bin/ssh` 做 `-L` 端口转发 | [04](04-ssh-tunnel.md) §1 |
| 数据网格 / 文本编辑器 | AppKit（`NSTableView` / `NSTextView`），其余用 SwiftUI | [06](06-ui-layer.md) §1、[07](07-data-grid.md) §1 |
| 编辑入口 | 网格只读，所有值修改在右侧字段栏 | [08](08-pending-changes.md) §8、[14](14-row-inspector.md) §1 |
| 编辑器智能替换 | `NSTextView` 的智能引号 / 破折号 / 文本替换 / 拼写纠正必须全部关闭 | [10](10-query-editor.md) §2 |
| 变更暂存 | 每个标签独立；提交包在一个事务里 | [08](08-pending-changes.md) §1、§5 |
| 行定位与可编辑性 | 用修改前冻结的旧值定位；没有主键的表整表只读（唯一索引不算数） | [08](08-pending-changes.md) §2.1、§7 |
| 大数据列 | 默认只取前 4 KB，点开时再取完整值；截断值绝不写回 | [07](07-data-grid.md) §3.1、[08](08-pending-changes.md) §9 |
| 元数据来源 | `information_schema` + TTL 缓存；行数用估算，不自动 `COUNT(*)` | [11](11-schema-and-import-export.md) §1、[07](07-data-grid.md) §3.4 |
| 表数据加载 | 不分页：固定 `LIMIT N` 从头取前 N 行，条数可切换；精确计数只在用户点「精确统计」时执行 | [07](07-data-grid.md) §7 |
| 导出方式 | 只支持 CSV；流式写出、临时文件原子替换 | [11](11-schema-and-import-export.md) §3、[13](13-open-questions.md) S9 |
| 口令存储 | 密码 / Passphrase 只进 Keychain，禁止写进 JSON / UserDefaults | [02](02-persistence.md) §2、§3 |
| 连接失效处理 | 不自动重连，保留未提交改动，由用户点「重新连接」 | [05](05-session-management.md) §6、[13](13-open-questions.md) L7 |
| 当前数据库 | 服务器默认库在「切库时」同步（发 `USE`），不在「执行时」同步；失败回滚选择；编辑器拦截手写 `USE` | [05](05-session-management.md) §11、[10](10-query-editor.md) §5.5、[13](13-open-questions.md) S38 |
| 启动行为 | **每次启动都进连接列表**，不自动连接、不自动进工作区；标签现场按连接记住，连上后才还原 | [05](05-session-management.md) §8、[13](13-open-questions.md) S36 |
| 只读模式 | 语句级拦截（不是权限控制） | [10](10-query-editor.md) §10、[13](13-open-questions.md) L3 |
| 工程组织 | XcodeGen，`TableLite.xcodeproj` 不进版本控制 | [12](12-build-and-deps.md) §1 |
| 第三方依赖 | 零 Swift Package 依赖 | [12](12-build-and-deps.md) §1、[13](13-open-questions.md) T10 |
| 沙箱与签名 | 不开沙箱、不签名、不公证 | [01](01-architecture.md) §5、[12](12-build-and-deps.md) §1 |
| 时区 | 客户端零处理：日期时间原样读、原样写，不解析不换算 | [03](03-mysql-layer.md) §4.3 |
| 存储版本 | 只做向前兼容读取；破坏性变更时备份重建，不写迁移代码 | [02](02-persistence.md) §9 |
| 界面语言 | 文案硬编码中文，不引入本地化资源 | [06](06-ui-layer.md) §8 |
| 可测试性 | 手写协议 + `AppEnvironment` 注入（`Clock` / `CredentialStore` / `FileSystemLocator`），不引入 DI 框架 | [15](15-testing.md) §3 |
| 分发 | `make run` 日常验证、`make dist` 出 Release zip；产物依赖目标机 Homebrew | [12](12-build-and-deps.md) §4.1 |
| App 图标 | 脚本矢量生成、不引入外部素材；尺寸对齐苹果图标网格；小尺寸参数化简化 | [12](12-build-and-deps.md) §7 |

「无主键表置为只读」这类**用户可感知的行为**由 `specs/` 定义（见 [`../../specs/04-data-editing.md`](../../specs/04-data-editing.md) §2），
实现侧的判定规则与文案见 [08-pending-changes.md](08-pending-changes.md) §7，不在这里重复。

## 约定

- 文档里的「必须 / 禁止」是硬性约束，实现时不得绕过；「建议」可权衡。
- 对应代码实现完成后，删掉已被代码取代的方案细节，**以代码为准**；但上表的关键决策不删。
- 涉及数据库写入的设计，默认选更安全的方案。
- 刻意简化的地方必须在 [13-open-questions.md](13-open-questions.md) 里登记。
