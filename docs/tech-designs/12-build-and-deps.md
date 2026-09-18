# 12 · 工程、依赖与构建

## 1. 技术选型（决策记录）

| 项 | 选择 | 理由 |
| --- | --- | --- |
| 语言 | Swift 6（严格并发） | 与 macOS 原生开发一致 |
| 主框架 | SwiftUI | 表单、布局、菜单开发效率高 |
| 数据网格 / 文本编辑器 | AppKit（`NSTableView` / `NSTextView`） | SwiftUI 不能满足大表滚动、冻结列、精确焦点与文本控制；右侧字段栏反过来用 SwiftUI（见 `14-row-inspector.md` §1） |
| 数据库访问 | libmysqlclient（Homebrew `mysql-client`）+ 薄 C shim | 协议行为与官方 `mysql` 客户端一致：多结果集、多语句、全部认证插件、流式读取。纯 Swift 实现（MySQLNIO）在多结果集、认证插件覆盖上有缺口 |
| SSH 隧道 | 系统 `/usr/bin/ssh` + `-L` 端口转发 | `~/.ssh/config`、`ProxyJump`、ssh-agent、known_hosts 全部免费获得 |
| 工程组织 | XcodeGen（`project.yml` 生成工程） | 文本可审阅、易 diff、无 pbxproj 冲突；纯 SwiftPM 做不了「C shim + .app bundle」 |
| 历史 / 日志存储 | 系统 `libsqlite3` | 零额外依赖 |
| 第三方 Swift Package | **零依赖** | 减少维护面；引入必须先在 `13-open-questions.md` 记录理由（T10） |

应用形态：自用工具，**不签名、不公证、不开沙箱**，最低 macOS 14。理由：需要读取 `~/.ssh/config` 与私钥、以用户身份启动 `ssh` 子进程、连接任意 TCP 主机。

## 2. Homebrew 依赖

| 包 | 用途 |
| --- | --- |
| `mysql-client` | `libmysqlclient` + 头文件，**keg-only**，必须显式指定路径 |
| `xcodegen` | 生成 Xcode 工程 |
| `openssl@3` / `zstd` | libmysqlclient 的传递依赖 |

安装：`brew install mysql-client xcodegen`。

## 3. 构建配置

- 用 `Configs/Local.xcconfig`（**不进版本控制**，由 `make deps` 生成）集中机器相关路径，而不是在 `project.yml` 里跑 `$(shell brew --prefix …)`（XcodeGen 的 `$(shell …)` 在增量构建与 CI 上不可靠）。
- 头文件与库路径、`LD_RUNPATH_SEARCH_PATHS` 必须显式给出（keg-only）。
- C shim 只编译，不链接 libmysqlclient（由 App target 链接）。

### 3.1 rpath 风险

`libmysqlclient.dylib` 依赖 `libssl` / `libcrypto` / `libzstd`，其 `install_name` 可能指向固定路径，也可能只写 `@rpath/...`。

**Phase 0 必须用 `otool -L` / `otool -l` 实测**：若某个依赖指向 keg-only 目录的**版本化绝对路径**（如 `/opt/homebrew/Cellar/openssl@3/3.x.y/lib`），Homebrew 升级后绝对路径会失效，需要 post-build 用 `install_name_tool` 改写为 `@rpath`。结论必须记录（T1）。

### 3.2 备选方案

若 rpath 太麻烦：把 `libmysqlclient` 及其依赖拷进 `.app/Contents/Frameworks/` 并改写所有引用为 `@rpath`。代价是「App 自包含、不依赖用户 Homebrew 环境」，多一个脚本多一处坏的可能。**默认不做**，作为备选记录（T1）。

## 4. 构建入口

Makefile 提供 `deps`（检查依赖 + 生成 `Local.xcconfig`）、`gen`（`xcodegen generate`）、`build`、`run`、`test`、`smoke`、`clean`。改动 `project.yml` 或新增文件后必须 `make gen`。

## 5. 版本控制

- **必须忽略**：构建产物、`*.xcodeproj`、`Configs/Local.xcconfig`、`xcuserdata/`、`*.xcworkspace`、`.DS_Store`。
- `TableLite.xcodeproj` 由 `project.yml` 生成，不进版本控制；`Local.xcconfig` 含机器相关路径，不进版本控制。

### 5.1 说明书发布

`manual/` 是纯静态 HTML，用 GitHub Pages 发布，**不引入任何构建步骤**：

- 站点根 = 仓库的 `manual/` 目录，其余目录不上线。
- 用 Actions 部署（workflow `pages.yml`），触发条件为 `manual/**` 变更或手动触发。
- 站点地址：<https://graycarl.github.io/TableLite/>
- **为什么不用分支部署**：分支部署只支持仓库根目录或 `/docs` 作为发布目录；改成 `docs/` 会与 `docs/tech-designs/` 冲突，把整站搬到根目录又会让仓库首页变成说明书。
- 页面之间只用相对路径引用，因此放在子路径下无需改动。

## 6. Phase 0 完成标准

- [ ] `make deps` 通过，`Configs/Local.xcconfig` 生成
- [ ] `make build` 产出 `.app`，`make run` 打开一个空窗口
- [ ] `otool -L` 检查通过，App 启动时不缺动态库
- [ ] 冒烟脚本的 7 项验证全部通过（见 `03-mysql-layer.md` §8）
- [ ] 退出 App 后没有残留的 ssh 进程
