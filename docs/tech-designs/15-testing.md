# 15 · 测试与验证

对应 `AGENTS.md` 的「纯逻辑必须写成可单元测试的纯函数」。本文件只记决策，实现以代码为准。

## 1. 支持的服务器版本（决策记录）

**只支持 MySQL，保证范围是 MySQL 8.0 及以上。不支持 MariaDB。**

- 实测依据：7 项冒烟验证（`03-mysql-layer.md` §8）在 `mysql:8.4.11` 上全部通过，
  客户端是 Homebrew `mysql-client` 26.7.0 提供的 libmysqlclient。
- 低于 8.0 的版本不做兼容分支，失败按服务器原始错误展示（`03-mysql-layer.md` §7）。
- **测试矩阵只有一档**：`mysql:8.4`。要验别的版本就把 `MYSQL_HOST` 指向它，跑同一个脚本。

## 2. 测试分层

| 层 | 位置 | 依赖 | 何时跑 |
| --- | --- | --- | --- |
| 单元测试 | `Tests/TableLiteTests/Unit/` | 无 IO | 每次 `make test` |
| 集成测试 | `Tests/TableLiteTests/Integration/` | 真数据库 | `make test`，没给 `MYSQL_HOST` 就 `XCTSkip` |
| 冒烟 | `Sources/TableLite/Core/MySQL/SmokeRunner.swift` | 真数据库 | `make smoke` |

- 单元测试只测纯逻辑：语句拆分、词法扫描、字面量生成、CSV 编解码、SSH 参数拼装、
  暂存区合并规则、过滤器 SQL 生成 —— 也就是 `AGENTS.md` 要求写成纯函数的那些。
- 集成测试测必须打真库的东西：`MySQLSession`、`MetaRepository`、SQLite 仓库、Keychain 替身。
- 命名 `<被测类型>Tests`，一个被测类型一个文件。
- **不做 UI 自动化测试**：验收清单就是 `manual/` 的 14 页，人工过一遍（S22）。
- **不设覆盖率门槛**：覆盖率不驱动这个项目的决策。
- `make test` 必须一条命令跑完所有不需要真库的测试。

## 3. 可测试性注入点（决策记录）

需要外部世界的东西都收在一个协议后面，由 `AppEnvironment` 在启动时注入；**不引入 DI 框架**。

| 协议 | 不抽就测不了什么 |
| --- | --- |
| `Clock` | 空闲回收 5 分钟、元数据 TTL、草稿防抖 1s、查询超时、SSH 就绪轮询 |
| `CredentialStore` | Keychain 在单测与 CI 里不可用，必须有内存实现 |
| `FileSystemLocator` | `Application Support` 路径、临时文件 + 原子替换、测试要指到临时目录 |

- 每个协议两份实现：`Live…`（真实）与 `InMemory…`（测试）。
- **暂缓**：`ProcessRunner` / `PortAllocator`（SSH 隧道用）留到 P10 再抽（T12）——
  现在抽只会猜错接口，而且隧道那套测试环境（可控 sshd）也还没定。
- 业务代码里**禁止**直接 `Date()` / `FileManager.default` / `SecItem*` / `Process`。

## 4. 依赖方向的自动校验

`01-architecture.md` §1 的「UI 层不得 `import CMySQLClient`」是硬约束，但编译器管不了。
用 `scripts/check-imports.sh` 做 grep 检查，挂在 `make test` 里，违规就失败。

## 5. CI（决策记录）

- 触发：`workflow_dispatch` + push 到 `main`。
- runner：**`xcode-27`**。这个镜像的基础系统就是 macOS 27，与部署目标一致
  （`12-build-and-deps.md` §3.3 的 T11 决策把部署目标定成了跟随构建机）。
  普通镜像（`macos-26` 及更早）装不下这个部署目标。
- 内容：`make deps` → `make build` → `make test`。
- **冒烟与集成测试不进 CI**：托管 macOS runner 没有 Docker，跑不了 `scripts/smoke/docker-compose.yml`；
  改用 brew 起 mysqld 会让 CI 的数据库和本地不是同一个东西，容易红且难排查。
  需要真库的验证以本地 `make smoke` 为准（L14）。
- `xcode-27` 目前是 preview 镜像，官方提示可能有排队问题。若 CI 变得很吵，先去掉这个 workflow。
