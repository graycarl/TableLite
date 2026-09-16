# 12 · 工程、依赖与构建

## 1. 技术选型（决策记录）

| 项 | 选择 | 理由 |
| --- | --- | --- |
| 语言 | Swift 6（严格并发） | 与 macOS 原生开发一致 |
| 主框架 | SwiftUI | 表单、布局、菜单开发效率高 |
| 数据网格 / 文本编辑器 | AppKit（`NSTableView` / `NSTextView`） | SwiftUI 不能满足大表滚动、冻结列、精确焦点控制与文本控制；右侧字段栏反过来用 SwiftUI（见 `14-row-inspector.md` §1） |
| 数据库访问 | **libmysqlclient**（Homebrew `mysql-client`）+ 薄 C shim | 协议行为与官方 `mysql` 客户端一致：多结果集、多语句、全部认证插件、`mysql_use_result` 流式。纯 Swift 实现（MySQLNIO）在多结果集、可 prepare 语句范围、认证插件覆盖上都有缺口 |
| SSH 隧道 | 系统 `/usr/bin/ssh` 子进程 + `-L` 端口转发 | `~/.ssh/config`、`ProxyJump`、ssh-agent、known_hosts 全部免费获得，无需自己实现 |
| 工程组织 | **XcodeGen**（`project.yml` 生成 `.xcodeproj`） | 声明式文本可审阅、易 diff、无 pbxproj 冲突；纯 SwiftPM 做不了「C shim + .app bundle」 |
| 历史 / 日志存储 | 系统 `libsqlite3` | 零额外依赖 |
| 第三方 Swift Package | **零依赖** | 减少维护面。需要引入时必须先在 `13-open-questions.md` 记录理由 |

应用形态：

- 自用工具，**不签名、不公证、不开沙箱**（`ENABLE_APP_SANDBOX = NO`）
- 最低系统版本 **macOS 14**
- 需要读取 `~/.ssh/config` 与私钥、需要启动 `ssh` 子进程、需要连接任意 TCP 主机 —— 开沙箱会处处受限

## 2. Homebrew 依赖

| 包 | 用途 | 备注 |
| --- | --- | --- |
| `mysql-client` | `libmysqlclient` + 头文件 | **keg-only**，必须显式指定路径 |
| `xcodegen` | 生成 Xcode 工程 | 仅构建期需要 |
| `openssl@3` | libmysqlclient 的依赖 | 传递依赖 |
| `zstd` | libmysqlclient 的依赖 | 传递依赖 |

安装：

```sh
brew install mysql-client xcodegen
```

`mysql-client` 是 keg-only，因此头文件与库不会软链到 `/opt/homebrew/include`、`/opt/homebrew/lib`，必须在构建设置里显式给出。

## 3. 构建配置

`project.yml`（XcodeGen）关键设置：

```yaml
name: TableLite
options:
  bundleIdPrefix: com.graycarl
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    ENABLE_USER_SCRIPT_SANDBOXING: NO
    DEAD_CODE_STRIPPING: YES
    MACOSX_DEPLOYMENT_TARGET: "14.0"

targets:
  CMySQLClient:
    type: library.static
    platform: macOS
    sources:
      - path: Sources/CMySQLClient
    settings:
      base:
        HEADER_SEARCH_PATHS: $(MYSQL_CLIENT_PREFIX)/include/mysql
        GCC_C_LANGUAGE_STANDARD: gnu11
        # 只编译，不链接 libmysqlclient（由 App target 链接）
        OTHER_CFLAGS: -fno-common

  TableLite:
    type: application
    platform: macOS
    sources:
      - path: Sources/TableLite
    dependencies:
      - target: CMySQLClient
    settings:
      base:
        INFOPLIST_FILE: Sources/TableLite/Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: Sources/TableLite/Resources/TableLite.entitlements
        CODE_SIGN_IDENTITY: "-"          # 本地临时签名即可
        CODE_SIGNING_REQUIRED: NO
        ENABLE_HARDENED_RUNTIME: NO
        PRODUCT_BUNDLE_IDENTIFIER: com.graycarl.tablelite
        HEADER_SEARCH_PATHS: $(MYSQL_CLIENT_PREFIX)/include/mysql
        LIBRARY_SEARCH_PATHS:
          - $(MYSQL_CLIENT_PREFIX)/lib
          - $(OPENSSL_PREFIX)/lib
          - $(ZSTD_PREFIX)/lib
        OTHER_LDFLAGS: -lmysqlclient -lssl -lcrypto -lz -lzstd -lresolv
        LD_RUNPATH_SEARCH_PATHS:
          - $(MYSQL_CLIENT_PREFIX)/lib
          - $(OPENSSL_PREFIX)/lib
          - $(ZSTD_PREFIX)/lib

  TableLiteTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/TableLiteTests]
    dependencies:
      - target: TableLite

configFiles:
  Debug: Configs/Local.xcconfig
  Release: Configs/Local.xcconfig
```

`Configs/Local.xcconfig`（不进版本控制，由 `make deps` 生成）：

```
MYSQL_CLIENT_PREFIX = /opt/homebrew/opt/mysql-client
OPENSSL_PREFIX = /opt/homebrew/opt/openssl@3
ZSTD_PREFIX = /opt/homebrew/opt/zstd
```

> 用 xcconfig 而不是在 `project.yml` 里写 `$(shell brew --prefix …)`：XcodeGen 的 `$(shell …)` 在增量构建与 CI 上不可靠，且路径随机器不同。把机器相关路径集中到一个不进版本控制的文件里更干净。

### 3.1 关于 rpath 的风险

`libmysqlclient.dylib` 依赖 `libssl` / `libcrypto` / `libzstd`。它的 `install_name` 可能指向 `/opt/homebrew/opt/openssl@3/lib/...`，也可能只写了 `@rpath/...`。

**Phase 0 必须先验证**：

```sh
otool -L "$(brew --prefix mysql-client)/lib/libmysqlclient.dylib"
otool -l  "$(brew --prefix mysql-client)/lib/libmysqlclient.dylib" | grep -A2 LC_RPATH
```

根据结果决定 `LD_RUNPATH_SEARCH_PATHS` 需要补哪些路径。若某个依赖是绝对路径且指向一个 keg-only 目录的**版本化路径**（`/opt/homebrew/Cellar/openssl@3/3.x.y/lib`），则 Homebrew 升级后绝对路径会失效——这时需要给 `.app` 加一个 `post-build` 脚本用 `install_name_tool` 改写为 `@rpath` 版本。**这个风险必须在 P0 验证并记录结论。**

### 3.2 另一种备选（如果 rpath 太麻烦）

把 `libmysqlclient` 及其依赖拷贝进 `.app/Contents/Frameworks/`，并用 `install_name_tool` 改写所有引用为 `@rpath`。工作量约半天，但换来「App 自包含、不依赖用户 Homebrew 环境」。**默认不做**（自用工具，多一个脚本多一处坏的可能），但作为 Phase 0 的备选记录下来。

## 4. 目录结构

```
TableLite/
├── project.yml
├── Makefile
├── Configs/
│   └── Local.xcconfig            # 生成物，gitignore
├── docs/
│   ├── README.md
│   ├── roadmap.md
│   └── tech-designs/
├── specs/
├── scripts/
│   ├── check-deps.sh
│   ├── gen-local-xcconfig.sh
│   └── smoke/                    # 访问层冒烟验证
├── Sources/
│   ├── CMySQLClient/
│   │   ├── include/CMySQLClient.h
│   │   ├── CMySQLClient.c
│   │   └── module.modulemap
│   └── TableLite/
│       ├── App/
│       ├── Core/
│       ├── Features/
│       └── Resources/
│           ├── Info.plist
│           └── TableLite.entitlements
└── Tests/
    └── TableLiteTests/
```

## 5. Makefile

```make
.PHONY: deps gen build run test clean smoke

deps:                  ## 检查并安装 Homebrew 依赖，生成 Local.xcconfig
	@./scripts/check-deps.sh
	@./scripts/gen-local-xcconfig.sh

gen: deps              ## 生成 Xcode 工程
	xcodegen generate

build: gen             ## 构建 .app（Debug）
	xcodebuild -project TableLite.xcodeproj -scheme TableLite \
	  -configuration Debug -derivedDataPath .build build

run: build             ## 构建并启动
	open .build/Build/Products/Debug/TableLite.app

test: gen              ## 跑单元测试
	xcodebuild -project TableLite.xcodeproj -scheme TableLite \
	  -derivedDataPath .build test

smoke: build           ## 访问层端到端验证（需要一个本地 MySQL）
	@./scripts/smoke/run.sh

clean:
	rm -rf .build TableLite.xcodeproj Configs/Local.xcconfig
```

`scripts/check-deps.sh` 的职责：

1. 检查 `xcodegen`、`mysql-client` 是否已安装，缺失时打印 `brew install …` 并退出 1
2. 打印实际前缀路径，方便排查
3. 检查 `libmysqlclient.dylib` 是否存在

`scripts/gen-local-xcconfig.sh` 的职责：

1. 用 `brew --prefix` 解析三个前缀
2. 写入 `Configs/Local.xcconfig`
3. 若内容未变化则不重写（避免触发无谓的重新构建）

## 6. 版本控制

`.gitignore` 至少包含：

```
.build/
DerivedData/
*.xcodeproj
Configs/Local.xcconfig
xcuserdata/
*.xcworkspace
.DS_Store
```

- `TableLite.xcodeproj` **不进版本控制**（由 `project.yml` 生成）
- `Configs/Local.xcconfig` 含机器相关路径，不进版本控制
- 用 git hook 或 `make` 前置检查防止误提交

## 7. 本地开发循环

```sh
make deps      # 首次
make gen       # project.yml 改动后
make build     # 构建
make test      # 单元测试
make run       # 跑起来
```

改动 `project.yml` 或新增文件后需要 `make gen` 重新生成工程。

## 8. Phase 0 完成标准

- [ ] `brew install mysql-client xcodegen` 完成
- [ ] `make deps` 通过，`Configs/Local.xcconfig` 生成
- [ ] `make build` 产出 `.app`
- [ ] `make run` 打开一个空窗口
- [ ] `otool -L` 检查通过，App 启动时不缺动态库
- [ ] 冒烟脚本的 7 项验证全部通过（见 `03-mysql-layer.md` §8）
- [ ] 冒烟脚本里跑一次「退出 App 后没有残留 ssh 进程」的检查
