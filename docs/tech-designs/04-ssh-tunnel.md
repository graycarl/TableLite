# 04 · SSH 隧道

## 1. 方案

调用系统自带的 `/usr/bin/ssh`，用 `-L` 做本地端口转发，把远端 MySQL 端口映射到本机临时端口；之后 `MySQLSession` 只连 `127.0.0.1:<临时端口>`，数据访问层不需要为 SSH 改动任何代码。

**为什么不用进程内实现（swift-nio-ssh / libssh2）**：`~/.ssh/config`、`ProxyJump`、ssh-agent、known_hosts、`Host` 匹配、`Include` 等能力全部免费获得，且与用户手动 `ssh` 的行为完全一致。

**代价与对策**：

| 代价 | 对策 |
| --- | --- |
| 多一个子进程要管生命周期 | 集中到 `SSHTunnel`，退出 / 断开时统一清理 |
| 密码认证需要交互 | `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` |
| 依赖 `/usr/bin/ssh` | macOS 自带；启动时检查存在性 |
| 拿不到结构化错误 | 解析 stderr；调试时用 `-v` 落盘 |

## 2. 配置模型

- 认证方式三选一：密码 / 私钥 / 交给 ssh 自己（config、agent、默认 key）。
- `host` 可以是 `~/.ssh/config` 里的别名；`jumpHost` 非空时透传 `-J`。
- 密码与 passphrase 不进配置文件，按需从 Keychain 取。

## 3. 命令拼装

命令拼装是**纯函数**（可单元测试），参数顺序固定。

- 固定开启：`ExitOnForwardFailure=yes`、`ServerAliveInterval` / `ServerAliveCountMax`、`ConnectTimeout`、`StrictHostKeyChecking=accept-new`、`-L`。
- 私钥认证才传 `-i` + `IdentitiesOnly=yes`；交由 ssh 自己时**不传任何 `-i`**、不强加 `-F`。
- 默认端口不传 `-p`；`--` 之后才是 `user@host`，防止 `host` 被解析成选项。
- 不使用 shell 启动进程，避免注入。

## 4. 本地端口分配

- 不预分配固定端口：bind `127.0.0.1:0` 取临时端口。
- 从关闭 socket 到 ssh 绑定之间存在窗口期；若 ssh 因端口占用退出，**重试最多 3 次**。

## 5. 认证

- 用 `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` 强制走 askpass（无 tty 场景）。
- 密码通过**子进程环境变量**传给一次性 askpass 脚本，不写进脚本文件；脚本权限 `0700`。
- 该机制会让 ssh 对所有提问都调用 askpass。因为已用 `accept-new` 自动接受新主机，正常不会有 host key 提问；若出现 known_hosts 冲突，askpass 会返回密码导致 ssh 失败退出——这是**期望行为**，不静默绕过安全告警，错误原样展示给用户。

## 6. 生命周期与状态机

- **懒启动**：只在真正要连数据库时启动隧道。
- **就绪判定不用固定 sleep**：轮询本地端口能否 connect，间隔 100ms、上限 15s；期间 ssh 退出则立即失败并带上 stderr。
- 监测死亡：进程终止回调 + 周期端口探测。
- 停止：`terminate()` → 等待 2s → 仍存活则 `SIGKILL`；ssh 用 `-N`，不会留下子进程。
- 隧道死亡 → 当前 `MySQLSession` 必然也断 → 标记 `disconnected`，UI 显示「重新连接」，**不自动重连**（L7）。
- App 退出时必须在 `applicationWillTerminate` 里同步停掉所有隧道，否则会残留 ssh 进程。

## 7. 完整连接流程

1. 建立隧道，拿到本地端口；
2. 用隧道端点创建 `MySQLSession`；
3. 打开连接（失败时按错误来源区分是 SSH 还是 MySQL）；
4. 状态置为已连接，拉取库列表、初始化对象树。

**硬约束**：SSH 失败与 MySQL 失败必须是不同的错误类型，UI 文案不能都是「连接失败」；SSH 失败要展示 stderr 的最后几行。

## 8. 直连模式

`enabled == false` 时使用直连端点，不创建隧道，代码路径与隧道模式完全一致。
