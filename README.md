# TableLite

macOS 原生的 MySQL / MariaDB 客户端。功能和交互参考 [TablePlus](https://tableplus.com/)，但只保留高频功能。

自用工具：不签名、不公证、不开沙箱，最低 macOS 14。

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
图上带编号，下面有控件说明表。直接开就行，不需要构建：

```sh
open manual/index.html
```

## 构建

依赖：[Homebrew](https://brew.sh/)、Xcode（含命令行工具）。

```sh
make deps      # 检查并安装依赖，生成 Configs/Local.xcconfig
make gen       # 用 XcodeGen 生成 TableLite.xcodeproj
make build     # 构建 .app
make run       # 构建并启动
make test      # 单元测试
make smoke     # 访问层端到端冒烟验证（需要一个本地 MySQL）
make clean
```

`make deps` 会用到：

| 包 | 用途 |
| --- | --- |
| `mysql-client` | `libmysqlclient`（keg-only，必须显式指定路径） |
| `xcodegen` | 从 `project.yml` 生成 Xcode 工程 |

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
├── scripts/             依赖检查、工程生成、冒烟验证
├── Sources/
│   ├── CMySQLClient/    libmysqlclient 的 C 封装
│   └── TableLite/       应用本体（Swift）
└── Tests/
```

## 已知限制

见 [`docs/tech-designs/13-open-questions.md`](docs/tech-designs/13-open-questions.md)。
