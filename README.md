# TableLite

macOS 原生的 MySQL 客户端。功能和交互参考 [TablePlus](https://tableplus.com/)，但只保留高频功能。

自用工具：不签名、不公证、不开沙箱。最低 macOS 版本跟随构建机的 Homebrew（当前 macOS 27，见 [`docs/tech-designs/12-build-and-deps.md`](docs/tech-designs/12-build-and-deps.md) §3.3）。

只支持 MySQL 8.0+（不含 MariaDB）。

## 当前状态

功能开发已完成（对应 [`docs/roadmap.md`](docs/roadmap.md) 的 M1–M3）：

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| **M1 可用** | 连接管理、对象树、数据网格、字段栏编辑、变更暂存 / 预览 / 提交（P0–P5） | ✅ |
| **M2 顺手** | 行 / 列过滤器、SQL 编辑器（高亮 / 多结果 / 历史 / Console Log）（P6–P7） | ✅ |
| **M3 完整** | CSV 导入导出、表结构视图、SSH 隧道、偏好设置、只读模式、App 图标（P8–P11） | ✅ |

主要能力：

- **连接管理**：新建 / 编辑 / 复制 / 删除，密码入钥匙串，测试连接分步报告，连接颜色与只读标记
- **主界面**：单窗口、连接切换器、库切换器、对象树（表 / 视图）、标签容器、状态栏、菜单快捷键
- **数据浏览**：分页、排序、列宽 / 列显隐（按表记忆）、值显示规则、快速查看、多种复制格式、右侧字段栏
- **数据编辑**：字段栏内编辑、增删改行、变更暂存、预览 SQL、事务提交 / 回滚、未提交确认
- **过滤**：行过滤器（14 种操作符 / 高级模式）、列过滤、跨列快速过滤
- **SQL 编辑器**：语法高亮、语句切分、多结果标签、执行 / 停止、查询历史、Console Log
- **导入导出**：CSV 流式导出（含过滤条件）与三步导入向导（可新建表）
- **表结构**：列 / 索引 / 外键 / 触发器 / 建表语句（带高亮）
- **SSH 隧道**：`ssh config` 别名 / 私钥 / 密码三种认证，跳板机，指纹变化明确失败
- **只读模式**：网格、SQL 编辑器、对象树危险操作、导入导出四处拦截

## 文档

| 想知道什么 | 去哪看 |
| --- | --- |
| 这个工具做什么、不做什么 | [`specs/00-scope.md`](specs/00-scope.md) |
| 界面长什么样、怎么操作 | [`specs/`](specs/README.md) |
| 界面到底长什么样（带图说明书） | [在线版](https://graycarl.github.io/TableLite/) 或 [`manual/index.html`](manual/index.html) — 浏览器打开 |
| 代码怎么组织、某块怎么实现 | [`docs/tech-designs/`](docs/tech-designs/README.md) |
| 先做哪一块、做到什么算完成 | [`docs/roadmap.md`](docs/roadmap.md) |
| 还没定的事情 | [`docs/tech-designs/13-open-questions.md`](docs/tech-designs/13-open-questions.md) |

**约定**：`specs/` 只放面向用户的需求设计（不含实现细节），`docs/tech-designs/` 放技术方案。需求变化先改 `specs/`。

## 使用说明书

[`manual/`](manual/README.md) 里有一套 14 页的 HTML 说明书，每个界面都用 SVG 线框图画出，
图上带编号，下面有控件说明表。也可以直接在 App 里通过「帮助 → 使用说明」打开在线版。

```sh
open manual/index.html
```

## 截图

> 占位：可放一张工作区截图（待补）。

## 系统要求

| 项 | 要求 |
| --- | --- |
| macOS | 跟随构建机系统版本（当前 macOS 27），不声称支持更低版本 |
| Xcode | 含命令行工具，需先 `sudo xcodebuild -license accept` 与 `xcodebuild -runFirstLaunch` |
| Homebrew | `mysql-client`、`openssl@3`、`zstd`、`xcodegen` |
| 运行期 | `make dist` 的产物依赖目标机器的 Homebrew（见 `13-open-questions.md` L13） |

## 构建

依赖：[Homebrew](https://brew.sh/)、Xcode（含命令行工具）。

首次在新机器上构建前，需要先接受 Xcode 许可并安装附加组件（两条都需要 sudo）：

```sh
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

```sh
make deps      # 检查依赖（缺失时打印修复命令），生成 Configs/Local.xcconfig
make gen       # 用 XcodeGen 生成 TableLite.xcodeproj
make build     # 构建 .app
make run       # 构建并启动
make test      # 单元测试（含 UI 层依赖方向检查）
make smoke     # 访问层端到端冒烟验证（自动起一个 Docker MySQL，需要 docker-compose）
#              用已有服务器：MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER=root \
#                            MYSQL_PASSWORD=xxx make smoke
make doctor    # 打印依赖与链接情况，排查构建问题
make dist      # 构建 Release 并打包成 dist/TableLite-<版本>.zip
make clean
```

`make deps` 会用到：

| 包 | 用途 |
| --- | --- |
| `mysql-client` | `libmysqlclient`（keg-only，必须显式指定路径） |
| `openssl@3` / `zstd` | `libmysqlclient` 的运行期依赖 |
| `xcodegen` | 从 `project.yml` 生成 Xcode 工程 |

App 图标由 [`scripts/make-appicon.swift`](scripts/make-appicon.swift) 生成（不引入外部素材）：

```sh
swift scripts/make-appicon.swift
```

## 目录

```
TableLite/
├── project.yml          XcodeGen 声明
├── Makefile
├── Configs/             机器相关路径配置（生成物，不进版本控制）
├── specs/               需求设计（面向用户）
├── manual/              图形化使用说明书（静态 HTML，浏览器打开）
├── docs/
│   ├── roadmap.md       实现路线图
│   └── tech-designs/    技术设计
├── scripts/             依赖检查、工程生成、App 图标、冒烟验证
├── Sources/
│   ├── CMySQLClient/    libmysqlclient 的 C 封装
│   └── TableLite/       应用本体（Swift）
└── Tests/
```

## 已知限制

见 [`docs/tech-designs/13-open-questions.md`](docs/tech-designs/13-open-questions.md)。

## 许可证

[MIT](LICENSE) © 2026 Hongbo He
