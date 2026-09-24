# 12 · 工程、依赖与构建

## 1. 技术选型（决策记录）

| 项 | 选择 | 理由 |
| --- | --- | --- |
| 语言 | Swift 6（严格并发） | 与 macOS 原生开发一致 |
| 主框架 | SwiftUI | 表单、布局、菜单开发效率高 |
| 数据网格 / 文本编辑器 | AppKit（`NSTableView` / `NSTextView`） | SwiftUI 不能满足大表滚动、冻结列、精确焦点与文本控制；右侧字段栏反过来用 SwiftUI（见 `14-row-inspector.md` §1） |
| 数据库访问 | libmysqlclient（Homebrew `mysql-client`，**静态链接**进 App）+ 薄 C shim | 协议行为与官方 `mysql` 客户端一致：多结果集、多语句、全部认证插件、流式读取。纯 Swift 实现（MySQLNIO）在多结果集、认证插件覆盖上有缺口 |
| SSH 隧道 | 系统 `/usr/bin/ssh` + `-L` 端口转发 | `~/.ssh/config`、`ProxyJump`、ssh-agent、known_hosts 全部免费获得 |
| 工程组织 | XcodeGen（`project.yml` 生成工程） | 文本可审阅、易 diff、无 pbxproj 冲突；纯 SwiftPM 做不了「C shim + .app bundle」 |
| 历史 / 日志存储 | 系统 `libsqlite3` | 零额外依赖 |
| 第三方 Swift Package | **零依赖** | 减少维护面；引入必须先在 `13-open-questions.md` 记录理由（T10） |

应用形态：自用工具，**不公证、不开沙箱**，最低 macOS 版本跟随构建机的 Homebrew（见 §3.3）。理由：需要读取 `~/.ssh/config` 与私钥、以用户身份启动 `ssh` 子进程、连接任意 TCP 主机。签名走**本机自签名**（见 §3.4）—— 不是为了过 Gatekeeper，而是为了让 Keychain 的「始终允许」授权在重新构建后仍然有效。

## 2. Homebrew 依赖

| 包 | 用途 |
| --- | --- |
| `mysql-client` | `libmysqlclient.a` + 头文件，**keg-only**，必须显式指定路径 |
| `openssl@3` / `zstd` / `zlib-ng-compat` | 与 `libmysqlclient.a` 一起被**静态链接**进 App（见 §3.1） |
| `xcodegen` | 生成 Xcode 工程 |

安装：`brew install mysql-client xcodegen`。后面三个是 `mysql-client` 的 formula 依赖，由它自动带入；它们是构建期静态链接的输入，少一个就是链接失败（不是运行期才发作），所以 `make deps` 的检查清单要覆盖（`scripts/check-deps.sh`）。

## 3. 构建配置

- 用 `Configs/Local.xcconfig`（**不进版本控制**，由 `make deps` 生成）集中机器相关路径，而不是在 `project.yml` 里跑 `$(shell brew --prefix …)`（XcodeGen 的 `$(shell …)` 在增量构建与 CI 上不可靠）。
- 头文件路径必须显式给出（keg-only）。**不需要** `LIBRARY_SEARCH_PATHS` 与 `LD_RUNPATH_SEARCH_PATHS`：静态链接没有动态库要找（§3.1）。
- C shim 只编译，不链接 libmysqlclient（由 App target 链接，且直接给 `.a` 的绝对路径而不是 `-l`）。

### 3.1 静态链接（决策记录，T1 于 2026-09-24 重定案）

**决策：App 把 Homebrew 的静态库直接链进二进制 —— `libmysqlclient.a`、`libssl.a`、`libcrypto.a`、`libzstd.a`、`libz.a`。产物不留任何 `/opt/homebrew` 的 dylib 引用。**

- 动机：让 `make dist` 的产物自包含 —— 换一台机器解开就能跑，不必先 `brew install mysql-client`。
- 前提：Homebrew 的 keg-only 目录里同时提供这些 `.a`（Phase 0 时只看了 `.dylib`，结论已不成立）。
- 必须显式加 `-lc++`：Swift target 不会自动带 C++ 运行库，而 `libmysqlclient` 是 C++ 实现的，漏了会报一片 `___cxa_throw` / `___gxx_personality_v0` undefined symbol。
- 实测（macOS 27 / `mysql-client` 26.7.0）：静态链接后 `otool -L` 只剩 `/usr/lib` 与 `/System/...`；`make smoke` 在 `mysql:8.4` 上全部验证项通过（含 TLS 与 `caching_sha2_password`）。
- 代价：
  - 体积：Debug 的 `TableLite.debug.dylib` 18 MB → 30 MB（Release 约 +12 MB）。
  - `openssl@3` / `zstd` 的安全更新必须重新 `make build` 才生效，静态链接吃不到动态库的补丁。
  - `mysql_native_password` 等外部认证插件**没有**内建（`nm` 检查确认只内建了 `caching_sha2_password` / `sha256_password`），连老服务器时仍要用 `lib/plugin/*.so`（L41）。
  - `minos` 不会因此降低（§3.3）。
- 边界：依赖的 keg-only 目录只需在**构建时**存在 —— 这正是这套方案的收益。
- 历史：Phase 0 曾据「依赖全部指向 `/opt/homebrew/opt/<formula>` 稳定符号链接」定案为动态链接；该定案未失效（今天仍成立），只是自包含的价值更高，故改。
- 回归防护：`scripts/package-dist.sh` 反过来断言产物里**一个** Homebrew 引用都没有，残留即失败。

### 3.2 备选方案（不采用）

| 方案 | 为什么不用 |
| --- | --- |
| 把 dylib 拷进 `.app/Contents/Frameworks/` 并改写为 `@rpath` | 效果与 §3.1 相同，但多一个 post-build 脚本、多一处会坏的地方 |
| 把预编译产物 vendor 进仓库（`Vendor/*.a`） | 仓库多 ~14 MB 二进制，还要自己维护升级流程；构建机装 Homebrew 对本项目不是负担 |
| 换 C 依赖来源（MySQL 官方 tarball / 自建） | 只在要降低 `minos`、支持更低 macOS 时才有必要（§3.3） |
| 舍弃 C 依赖，改纯 Swift 协议实现 | §1 已否（多结果集、认证插件覆盖有缺口） |

### 3.3 部署目标（决策记录，T11 已定案）

Homebrew 的 bottle 按构建时的系统构建，`minos` 会写进 dylib 本身（实测在 macOS 27 上：`libmysqlclient` / `libssl` = 27.0、`libzstd` = 26.0），无法通过搬运文件降低。

**决策：`MACOSX_DEPLOYMENT_TARGET` 与构建机系统版本保持一致（当前 27.0），不声称支持更低版本。**

- 理由：自用单机工具。在低于依赖 `minos` 的系统上运行是 Apple 不支持的组合 —— 行为未定义（可能加载期 `Symbol not found`，也可能运行到某个调用路径才崩溃）。把声明写成实际能做到的值，比留一个无法验证的承诺要好。
- 副作用（正面）：`Info.plist` 的 `LSMinimumSystemVersion` 也随之变成 27.0，旧系统会直接拒给启动，而不是进入未定义行为。
- 实测澄清：`minos` **并不阻止 dyld 加载**（在 macOS 27 上 `dlopen` 一个 `minos` = 99.0 的 dylib 成功）。所以这不是「启动即失败」，而是「未定义行为」。
- §3.2 的「内嵌 dylib / vendor 预编译产物」**降低不了 `minos`**，与本决策无关。
- 升级 macOS 后需同步这个值（`make deps` 不会自动改），否则链接警告会重新出现。
- 若将来确实要支持更低系统，需在旧 SDK 上自建 dylib，或改用 MySQL 官方 tarball 的库 —— 届时重开此决策，并重新评估 `03-mysql-layer.md` 锁定的「Homebrew `mysql-client`」方案。
- **静态链接（§3.1）降低不了 `minos`**：`.a` 里的目标文件本身就带 `minos 27.0`，链接产物仍是 27.0（实测）。

### 3.4 代码签名：本机自签名（决策记录，2026-09-25）

**问题**：ad-hoc 签名（`CODE_SIGN_IDENTITY = -`）下 App 的「代码身份」就是二进制的哈希 —— `codesign -dvvv` 显示
`designated => cdhash H"…"`。改一行代码重新构建，哈希就变，Keychain 里「始终允许」记住的授权随之失效，
每个条目（MySQL 密码 / SSH 密码 / SSH 私钥口令）都要重新授权一次。Debug 构建把代码放进
`TableLite.debug.dylib` 也救不了：41 KB 的主二进制壳会跟着一起变（实测 `bd44a621…` → `78af6315…`）。

**决策：开发机用一张本机自签名的 code signing 证书签名；构建机上没有该证书时自动退回 ad-hoc。**

- 一次性生成：`make signing`（`scripts/dev/codesign-identity.sh`）在登录钥匙串里建出 `TableLite Local Dev`
  证书并导入私钥，再把签名身份写进 `Configs/Local.xcconfig`（该文件不进版本控制）。脚本幂等，
  重复跑不会换掉已存在的证书。
- 自签名证书还必须在 user 域标为「受信任的代码签名证书」（`security add-trusted-cert -r trustRoot -p codeSign`，
  不需要 sudo）：不加的话 `find-identity` 报 `CSSMERR_TP_NOT_TRUSTED`，codesign 直接说 `no identity found`。
  脚本会自己补上；要撤销就在钥匙串访问里删掉该证书的代码签名信任。
- 签出来的 DR 是 `identifier "com.graycarl.tablelite" and certificate leaf = H"…"`：只跟 bundle id 与证书绑定，
  **与代码内容无关**，所以重构建、Debug / Release 互换都命中同一批 Keychain 授权。
- 接线必须走变量间接：`project.yml` 里写 `CODE_SIGN_IDENTITY: $(TABLELITE_CODESIGN_IDENTITY:default=-)`，
  由 `scripts/gen-local-xcconfig.sh` 在发现该身份时把变量写进 `Configs/Local.xcconfig`。
  **不能**直接把身份写进 `Configs/Local.xcconfig` —— target 级设置会盖住工程级 xcconfig（实测）。
- 边界：
  - 证书是**机器本地状态**，不进仓库；换机 / 证书丢失后重新 `make signing`，Keychain 会重新授权一次（DR 变了）。
  - `spctl` 依旧 reject（自签名过不了 Gatekeeper），实际影响与 ad-hoc 时期相同：本机构建产物没有 quarantine
    属性，`open` 照常启动。**不公证**这条没变（`specs/00-scope.md` 的 D3）。
  - 只解决 Keychain 重复授权；「不开沙箱」「不做 hardened runtime」这两条也没变（§1、`01-architecture.md` §5）。
  - 想彻底没有 ACL 与授权弹窗（data protection keychain）必须先有真 Apple 签名 + provisioning profile：
    实测 ad-hoc 签名 + 手写 `keychain-access-groups` entitlement 的进程会被 AMFI `Killed: 9`。见 `13-open-questions.md` T13。

## 4. 构建入口

Makefile 提供 `deps`（检查依赖 + 生成 `Local.xcconfig`）、`gen`（`xcodegen generate`）、`build`、`run`、`test`、`smoke`、`signing`（建/导入本机自签名证书，见 §3.4）、`clean`。改动 `project.yml` 或新增文件后必须 `make gen`。

手工测试用数据库：`make db` 用 `scripts/dev/docker-compose.yml` 起一个**常驻**容器（镜像同冒烟的 `mysql:8.4`，
但 compose 文件、容器名、端口均独立：默认 **13307**，冒烟是 13306，两者可同时运行）。
数据存在容器自己的 named volume 里，示例数据由 `scripts/dev/seed.sql` 首次创建时灌入；
配 `db-reset` / `db-shell` / `db-stop`。与冒烟的区别在于：冒烟跑完即删，这个留着给 App 连。

**首次在一台新机器上构建前**，还需要接受 Xcode 许可并安装附加组件（两条都需要 sudo）：

```sh
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

不做的报错分别是 `You have not agreed to the Xcode license agreements` 与 `IDESimulatorFoundation` 插件加载失败。

### 4.1 分发（`make dist`）

日常验证用 `make run`（Debug）；要归档时用 `make dist`。

- Release 配置构建，产出 `dist/TableLite-<版本>.zip`；用 `ditto -c -k --keepParent` 打包，保留扩展属性。
- 打包前断言 `otool -L` 里**没有**任何 `/opt/homebrew` 引用，有一处就失败 —— 这是一道回归门，防的是链接配置被改回动态链接（§3.1）。
- **产物不依赖目标机器的 Homebrew**，换机解开就能跑。唯一例外是用 `mysql_native_password` 等外部认证插件连老服务器时（L41）。
- 签名用同一张本机自签名证书（§3.4），**不公证**（`specs/00-scope.md` 的 D3）；构建机上没有这张证书时退回 ad-hoc。

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
- [ ] `otool -L` 检查通过，App 启动时不缺动态库，且**没有** `/opt/homebrew` 引用。**注意 Xcode 27 的 Debug 构建会把实际代码放进 `TableLite.debug.dylib`，主二进制只是个壳 —— 要检查的是 `TableLite.app/Contents/MacOS/TableLite.debug.dylib`；Release 构建才直接看主二进制**
- [ ] 冒烟脚本的 7 项验证全部通过（见 `03-mysql-layer.md` §8）
- [ ] 退出 App 后没有残留的 ssh 进程

## 7. App 图标（决策记录）

- **脚本生成，不引入外部素材**：`scripts/make-appicon.swift` 用 CoreGraphics 画图，一次产出 `AppIcon.appiconset` 的全部尺寸与 `Contents.json`。改图标＝改脚本再跑一次，仓库里没有设计源文件（与 §1 的「零第三方依赖」一致）。
- **构图**：靛蓝渐变圆角方块 + 白色数据表面板（浅灰网格、单元格里的数据条），其中一整行用薄荷色高亮 —— 直接对上产品主场景「可编辑的数据网格」。
- **尺寸对齐苹果图标网格**：1024 画布里形状 816×816、阴影 offset −4 / blur 18，不透明包围盒落在上 88 / 左右 80 / 下 72，与系统自带图标一致。**不要**画满 1024 的方块 —— 那在 Dock 里比邻居大一圈。
- **小尺寸不单独出美术稿**：16 / 32 / 64 px 由同一套绘制参数按尺寸切换（减少行列、加粗网格线、去掉数据条），只保证轮廓与高亮行可辨（S37）。
