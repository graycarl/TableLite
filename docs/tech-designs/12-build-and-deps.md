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

应用形态：自用工具，**不签名、不公证、不开沙箱**，最低 macOS 版本跟随构建机的 Homebrew（见 §3.3）。理由：需要读取 `~/.ssh/config` 与私钥、以用户身份启动 `ssh` 子进程、连接任意 TCP 主机。

## 2. Homebrew 依赖

| 包 | 用途 |
| --- | --- |
| `mysql-client` | `libmysqlclient` + 头文件，**keg-only**，必须显式指定路径 |
| `xcodegen` | 生成 Xcode 工程 |
| `openssl@3` / `zstd` / `zlib-ng-compat` | `libmysqlclient` 的**运行期**硬依赖 |

安装：`brew install mysql-client xcodegen`。上面三个传递依赖由 `mysql-client` 的 formula 自动带入，但它们是运行期硬依赖，`make deps` 的检查清单需要覆盖（见 `scripts/check-deps.sh`）。

## 3. 构建配置

- 用 `Configs/Local.xcconfig`（**不进版本控制**，由 `make deps` 生成）集中机器相关路径，而不是在 `project.yml` 里跑 `$(shell brew --prefix …)`（XcodeGen 的 `$(shell …)` 在增量构建与 CI 上不可靠）。
- 头文件与库路径、`LD_RUNPATH_SEARCH_PATHS` 必须显式给出（keg-only）。
- C shim 只编译，不链接 libmysqlclient（由 App target 链接）。

### 3.1 rpath 处理（决策记录，T1 已定案）

Phase 0 用 `otool -L` / `otool -l` 实测（macOS 27 / `mysql-client` 26.7.0）：

- `libmysqlclient.dylib` 的 `LC_ID_DYLIB` 与它的全部依赖都指向 `/opt/homebrew/opt/<formula>/lib/…`，**没有指向版本化 Cellar 路径**（如 `/opt/homebrew/Cellar/openssl@3/3.6.4/lib`）的引用，`LC_RPATH` 为空。
- `/opt/homebrew/opt/<formula>` 是 Homebrew 维护的稳定符号链接，升级 formula 不会改变它。

**结论：不做任何处理。** 不写 post-build `install_name_tool`，也不把 dylib 拷进 `.app`（§3.2 不采用）。

- 前提：依赖的 keg-only 目录在运行时存在 —— 自用工具已接受（§1）。
- 代价：`libmysqlclient.<major>.dylib` 的 ABI 大版本号会写进 App 二进制。Homebrew 升级到下一个 ABI 大版本后必须重新 `make build`，否则启动即 `dyld` 失败。
- 附带结论：`-lz` 解析到系统 `/usr/lib/libz.1.dylib`，不是 keg-only 的 `zlib-ng-compat`，App 侧少一个外部依赖；但 `libmysqlclient` 自身链接了 `zlib-ng-compat` 的 `libz.1.dylib`，运行时仍必须有该 formula（§2）。

### 3.2 备选方案（不采用）

把 `libmysqlclient` 及其依赖拷进 `.app/Contents/Frameworks/` 并改写引用为 `@rpath`。代价是「App 自包含、不依赖 Homebrew 环境」，多一个脚本多一处坏的可能。§3.1 实测表明没有必要，**不采用**；只有将来要在没有 Homebrew 的机器上运行时再重新评估。

### 3.3 部署目标（决策记录，T11 已定案）

Homebrew 的 bottle 按构建时的系统构建，`minos` 会写进 dylib 本身（实测在 macOS 27 上：`libmysqlclient` / `libssl` = 27.0、`libzstd` = 26.0），无法通过搬运文件降低。

**决策：`MACOSX_DEPLOYMENT_TARGET` 与构建机系统版本保持一致（当前 27.0），不声称支持更低版本。**

- 理由：自用单机工具。在低于依赖 `minos` 的系统上运行是 Apple 不支持的组合 —— 行为未定义（可能加载期 `Symbol not found`，也可能运行到某个调用路径才崩溃）。把声明写成实际能做到的值，比留一个无法验证的承诺要好。
- 副作用（正面）：`Info.plist` 的 `LSMinimumSystemVersion` 也随之变成 27.0，旧系统会直接拒给启动，而不是进入未定义行为。
- 实测澄清：`minos` **并不阻止 dyld 加载**（在 macOS 27 上 `dlopen` 一个 `minos` = 99.0 的 dylib 成功）。所以这不是「启动即失败」，而是「未定义行为」。
- §3.2 的「内嵌 dylib」**降低不了 `minos`**，与本决策无关。
- 升级 macOS 后需同步这个值（`make deps` 不会自动改），否则链接警告会重新出现。
- 若将来确实要支持更低系统，需在旧 SDK 上自建 dylib，或改用 MySQL 官方 tarball 的库 —— 届时重开此决策，并重新评估 `03-mysql-layer.md` 锁定的「Homebrew `mysql-client`」方案。

## 4. 构建入口

Makefile 提供 `deps`（检查依赖 + 生成 `Local.xcconfig`）、`gen`（`xcodegen generate`）、`build`、`run`、`test`、`smoke`、`clean`。改动 `project.yml` 或新增文件后必须 `make gen`。

**首次在一台新机器上构建前**，还需要接受 Xcode 许可并安装附加组件（两条都需要 sudo）：

```sh
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

不做的报错分别是 `You have not agreed to the Xcode license agreements` 与 `IDESimulatorFoundation` 插件加载失败。

### 4.1 分发（`make dist`）

日常验证用 `make run`（Debug）；要归档时用 `make dist`。

- Release 配置构建，产出 `dist/TableLite-<版本>.zip`；用 `ditto -c -k --keepParent` 打包，保留扩展属性。
- 打包前逐个检查 `otool -L` 里的 Homebrew 依赖是否还在，缺一个就失败 —— 否则会得到一个看起来正常、换机就跑不起来的 zip。
- **产物仍依赖目标机器的 Homebrew**（`mysql-client` / `openssl@3` / `zstd`，见 §3.1）。换机前先 `brew install mysql-client`（L13）。
- 不签名、不公证（`specs/00-scope.md` 的 D3）。

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
- [ ] `otool -L` 检查通过，App 启动时不缺动态库。**注意 Xcode 27 的 Debug 构建会把实际代码放进 `TableLite.debug.dylib`，主二进制只是个壳 —— 要检查的是 `TableLite.app/Contents/MacOS/TableLite.debug.dylib`；Release 构建才直接看主二进制**
- [ ] 冒烟脚本的 7 项验证全部通过（见 `03-mysql-layer.md` §8）
- [ ] 退出 App 后没有残留的 ssh 进程

## 7. App 图标（决策记录）

- **脚本生成，不引入外部素材**：`scripts/make-appicon.swift` 用 CoreGraphics 画图，一次产出 `AppIcon.appiconset` 的全部尺寸与 `Contents.json`。改图标＝改脚本再跑一次，仓库里没有设计源文件（与 §1 的「零第三方依赖」一致）。
- **构图**：靛蓝渐变圆角方块 + 白色数据表面板（浅灰网格、单元格里的数据条），其中一整行用薄荷色高亮 —— 直接对上产品主场景「可编辑的数据网格」。
- **尺寸对齐苹果图标网格**：1024 画布里形状 816×816、阴影 offset −4 / blur 18，不透明包围盒落在上 88 / 左右 80 / 下 72，与系统自带图标一致。**不要**画满 1024 的方块 —— 那在 Dock 里比邻居大一圈。
- **小尺寸不单独出美术稿**：16 / 32 / 64 px 由同一套绘制参数按尺寸切换（减少行列、加粗网格线、去掉数据条），只保证轮廓与高亮行可辨（S37）。
