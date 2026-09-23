# TableLite 需求设计

TableLite 是一个 macOS 原生的 MySQL 客户端，功能和交互参考 TablePlus，但只保留高频功能。

**本目录只描述「用户能看到、能操作、能预期」的东西**——界面结构、交互规则、行为边界、错误提示的措辞。技术方案、数据结构、SQL 生成规则、构建方式等实现细节在 [`../docs/tech-designs/`](../docs/tech-designs/README.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [00-scope.md](00-scope.md) | 产品定位、功能范围、非目标、已确认的产品决策 |
| [01-connections.md](01-connections.md) | 连接列表、连接配置表单、连接状态与切换 |
| [02-workspace.md](02-workspace.md) | 主界面结构、对象树、Tab、状态栏、菜单与快捷键 |
| [03-data-browsing.md](03-data-browsing.md) | 浏览表数据：限量加载、排序、单元格显示、快速查看、复制 |
| [04-data-editing.md](04-data-editing.md) | 编辑数据、变更暂存、预览、提交、放弃 |
| [05-filtering.md](05-filtering.md) | 行过滤与列过滤 |
| [06-query-editor.md](06-query-editor.md) | SQL 编辑器、执行、结果展示、查询历史、Console Log |
| [07-schema-view.md](07-schema-view.md) | 表结构只读视图 |
| [08-import-export.md](08-import-export.md) | 数据导入与导出 |
| [09-readonly-mode.md](09-readonly-mode.md) | 连接级只读模式 |
| [10-ssh-tunnel.md](10-ssh-tunnel.md) | SSH 隧道的配置项与用户可见行为 |
| [11-preferences.md](11-preferences.md) | 偏好设置项清单 |
| [12-feedback.md](12-feedback.md) | 提示、确认、错误信息的呈现规范 |

## 约定

- **界面语言：中文。** SQL 关键字、协议术语、类型名保持英文。
- 文档中的「必须 / 禁止」是硬性约束；「建议」是可权衡项。
- 所有涉及数据写入的设计，优先选择更安全的方案。
- 需求变更请先改本目录，再评估 `docs/tech-designs/` 的连带影响。

## 技术方案索引

- [技术设计总览](../docs/tech-designs/README.md)
- [实现路线图](../docs/roadmap.md)
