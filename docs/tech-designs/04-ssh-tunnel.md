# 04 · SSH 隧道

## 1. 方案

调用系统自带的 `/usr/bin/ssh`，用 `-L` 做本地端口转发，把远端 MySQL 端口映射到本机一个临时端口。之后 `MySQLSession` 连 `127.0.0.1:<临时端口>` 即可，不需要为 SSH 改动数据访问层的任何代码。

**为什么不用进程内实现（swift-nio-ssh / libssh2）**：`~/.ssh/config`、`ProxyJump`、ssh-agent、known_hosts、各种 `Host` 匹配规则、`Include` 指令……这些能力自己实现工作量巨大且容易出错。系统 ssh 全部免费提供，且与用户手动 `ssh` 的行为完全一致。

**代价与对策**：

| 代价 | 对策 |
| --- | --- |
| 多一个子进程要管生命周期 | 集中到 `SSHTunnel` 一个类，App 退出/连接关闭时统一清理 |
| 密码认证需要交互 | 用 `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` |
| 依赖 `/usr/bin/ssh` | macOS 自带，永远存在；启动时检查存在性 |
| 无法拿到 ssh 的结构化错误 | 解析 stderr；`-v` 时写调试日志文件 |

## 2. 配置模型

```swift
struct SSHConfig: Sendable, Codable, Equatable {
    var enabled: Bool
    var host: String                 // 可以是 ~/.ssh/config 里的 Host 别名
    var port: UInt16 = 22
    var user: String
    var authMethod: AuthMethod = .agentOrConfig
    var privateKeyPath: String?      // authMethod == .privateKey 时使用，支持 ~ 展开
    var useConfigHostAlias: Bool = true
    var jumpHost: String?            // "user@proxy:22"，非空时传 -J

    enum AuthMethod: String, Codable, Sendable {
        case password        // 使用 Keychain 里的密码，通过 SSH_ASKPASS
        case privateKey      // -i <path>，Passphrase 通过 SSH_ASKPASS
        case agentOrConfig   // 不传 -i/-o，完全交给 ssh 自己（config / agent / 默认 key）
    }
}
```

## 3. 命令拼装

`SSHCommandBuilder`（纯函数，可单元测试）：

```swift
struct SSHCommandBuilder {
    static func arguments(config: SSHConfig, localPort: UInt16,
                          remoteHost: String, remotePort: UInt16) -> [String]
    static func environment(for authMethod: SSHConfig.AuthMethod,
                            askPassScript: URL?) -> [String: String]
}
```

生成的参数（顺序固定，便于测试）：

```
-N                                       # 不执行远端命令
-o ExitOnForwardFailure=yes              # 端口转发失败就退出，不要静默挂着
-o ServerAliveInterval=15
-o ServerAliveCountMax=3
-o ConnectTimeout=10
-o StrictHostKeyChecking=accept-new      # 首次自动接受，已存在的不匹配仍然报错
-o BatchMode=no
-L 127.0.0.1:<localPort>:<remoteHost>:<remotePort>
[-p <config.port>]                       # 仅当 != 22
[-i <expandedKeyPath>]                   # authMethod == .privateKey
[-o IdentitiesOnly=yes]                  # 仅当指定了 -i
[-J <jumpHost>]                          # jumpHost 非空
[--] <user>@<host>
```

补充规则：
- `authMethod == .agentOrConfig` 时**不传任何 `-i`**，并且不强加 `-F`，让 ssh 走默认的 `~/.ssh/config`
- `useConfigHostAlias == false` 时，对 `host` 追加 `-o HostName=<host>`（当 `host` 是别名但用户想覆盖时）
- 不传 `-o LogLevel`，除非用户打开了「SSH 调试日志」偏好，此时加 `-v` 并把 stderr 落盘到 `~/Library/Logs/TableLite/ssh-<connId>.log`

## 4. 本地端口分配

不预分配固定端口（避免冲突与残留）。做法：

1. 创建 `socket(AF_INET, SOCK_STREAM, 0)` → `bind` 到 `127.0.0.1:0` → `getsockname` 得到端口 → `close`
2. 用这个端口传给 `-L`
3. 因为存在「关闭到 ssh 绑定」的窗口期，若 ssh 因 `ExitOnForwardFailure` 退出并提示端口被占用，**重试最多 3 次**

## 5. 认证：密码与 Passphrase

ssh 在没有 tty 且设置了 `SSH_ASKPASS` 时会调用该程序询问密码。macOS 的 ssh 支持 `SSH_ASKPASS_REQUIRE=force`，可以强制走 askpass。

实现：

1. 在 `~/Library/Application Support/TableLite/askpass/askpass.sh` 写一个脚本（权限 `0700`）：
   ```sh
   #!/bin/sh
   printf '%s\n' "$TABLELITE_SSH_SECRET"
   ```
   > 不把密码写进脚本文件，而是通过**子进程环境变量**传递。环境变量泄漏风险可用「一次性脚本 + 进程启动后立即从内存清除 + 删除脚本」缓解。
   > 更严做法：把密码写进一个 `0600` 的临时文件，脚本读该文件后立即 `unlink`；本设计采用环境变量法，实现更简单，风险可接受（同用户下其他进程本就能读 Keychain）。
2. 启动 ssh 时设置：
   ```
   SSH_ASKPASS=<脚本路径>
   SSH_ASKPASS_REQUIRE=force
   DISPLAY=:0
   TABLELITE_SSH_SECRET=<密码或 Passphrase>
   ```
3. `Process.standardInput` 接到 `/dev/null`、`standardOutput` 接到 `Pipe()`（丢弃），`standardError` 接到 `Pipe()` 用于收集错误文本
4. 密码不落盘；Passphrase 从 Keychain 取

**注意**：`SSH_ASKPASS_REQUIRE=force` 会让 ssh 对**所有**提问（包括 host key 确认）都调用 askpass。因为我们已经用 `StrictHostKeyChecking=accept-new` 自动接受新主机，正常情况不会有 host key 提问。若仍出现（例如 known_hosts 冲突），askpass 脚本会返回密码而不是 `yes`，ssh 会失败并退出——这是**期望行为**（不静默绕过安全告警），错误信息会原样展示给用户。

## 6. 生命周期与状态机

```swift
@MainActor
final class SSHTunnel {
    enum State: Equatable {
        case idle
        case starting
        case ready(localPort: UInt16)
        case failed(reason: String)
        case stopped
    }
    private(set) var state: State
    private var process: Process?
    private var stderrBuffer: String   // 最近 8 KB

    func start(remoteHost: String, remotePort: UInt16) async throws -> UInt16
    func stop()
    var isAlive: Bool { get }
}

@MainActor
final class ConnectionSession {
    private var tunnel: SSHTunnel?
    // …
    func ensureTunnel() async throws -> EndPoint
}
```

规则：
1. **懒启动**：只在真正要连数据库时启动隧道。
2. **就绪判定**：不能用固定 `sleep`。做法是轮询「本地端口能否 connect 成功」，间隔 100ms，上限 15s；期间若 ssh 进程退出则立即失败并抛出 stderr 内容。
3. **监测死亡**：`Process.terminationHandler` + 每 5s 的端口探测。
4. **失败处理**：隧道死亡 → 当前 `MySQLSession` 必然也断 → 标记为 `disconnected`，UI 状态栏红色 + 「重新连接」按钮（不自动重连，避免在用户不知情时反复尝试）。
5. **停止**：`process.terminate()` → 等 2s → 若仍存活则 `kill(pid, SIGKILL)`。同时确保不留下子进程（ssh 用 `-N`，不会有子进程）。
6. **App 退出**：`applicationWillTerminate` 里同步 stop 所有隧道（`NSApplication` 退出前必须完成，否则会残留 ssh 进程）。
7. **进程组**：设置 `Process` 的 `executableURL = /usr/bin/ssh`，不使用 shell，避免注入。

## 7. 完整连接流程

```
ConnectionSession.connect():
  1. 状态 → connecting("正在建立 SSH 隧道…")
  2. tunnel.start(remoteHost: mysqlHost, remotePort: mysqlPort)
       → localPort = 127.0.0.1:<port>
  3. MySQLSession(config:, endPoint: .tunnel(localPort: localPort))
  4. mysqlSession.open()
       · 失败且 authMethod 是 password → 提示密码错误（可能是 SSH 密码而非 MySQL 密码）
         → 通过区分错误来源给出明确提示（SSH 失败会带 stderr，MySQL 失败带 errno）
  5. 状态 → connected
  6. 拉取库列表、初始化对象树
```

**错误区分要点**：SSH 隧道的失败阶段（步骤 2）与 MySQL 的失败阶段（步骤 4）必须用不同的错误类型，UI 文案不能都是「连接失败」。SSH 失败时展示 stderr 的最后几行（例如 `Permission denied (publickey).`）。

## 8. 直连模式

`SSHConfig.enabled == false` 时，`EndPoint.direct(host:port:)`，不创建隧道，代码路径完全一致。

## 9. 单元测试

`SSHCommandBuilderTests` 必须覆盖：

| 场景 | 期望 |
| --- | --- |
| 最简：密码认证、默认端口 | 不含 `-p 22`、不含 `-i`、含 `-L 127.0.0.1:<local>:<remoteHost>:<remotePort>` |
| 私钥认证 | 含 `-i <expanded>` 与 `-o IdentitiesOnly=yes` |
| 非默认端口 | 含 `-p 2222` |
| JumpHost | 含 `-J user@proxy:22` |
| 自定义 localPort / 远端 host:port | `-L` 精确匹配 |
| `agentOrConfig` | 不含 `-i`、不含 `-o IdentitiesOnly` |
| 目标参数顺序 | `--` 之后是 `user@host`（防止 `host` 被解析成选项） |

---

## 附：`mtl_conn_cancel` 补充声明

`03-mysql-layer.md` 第 2 节的 C 头文件中还需补充：

```c
/* 请求中止当前正在执行的查询。可从任意线程调用。 */
void mtl_conn_cancel(MTLConn *c);
```
