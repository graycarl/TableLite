#!/bin/bash
# 隔离调试 profile 的路径、种子数据与生命周期（docs/tech-designs/15-testing.md §9.1）。
#
# 由 tl.sh source；不要单独执行。

PROFILE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROFILE_DIR="${TL_DEV_DIR:-$PROFILE_ROOT/.build/dev-data}"
PROFILE_SUITE="${TL_DEV_SUITE:-com.graycarl.tablelite.dev}"
PROFILE_APP="$PROFILE_ROOT/.build/Build/Products/Debug/TableLite.app/Contents/MacOS/TableLite"
PROFILE_PID_FILE="$PROFILE_DIR/app.pid"
PROFILE_READY="$PROFILE_DIR/ready.json"
PROFILE_LOG="$PROFILE_DIR/run.log"
# 真实存储根 / 主偏好域：`reset`、种子写入前的安全检查要用（与 App 侧同一组硬约束）。
PROFILE_LIVE_ROOT="$HOME/Library/Application Support/TableLite"
PROFILE_MAIN_SUITE="com.graycarl.tablelite"

# 种子连接（隔离 profile 里叫 demo，指向 dev MySQL）
PROFILE_DB_HOST="${MYSQL_HOST:-127.0.0.1}"
PROFILE_DB_PORT="${MYSQL_PORT:-13307}"
PROFILE_DB_USER="${MYSQL_USER:-root}"
PROFILE_DB_PASSWORD="${MYSQL_PASSWORD:-tablelite}"
PROFILE_DB_NAME="${MYSQL_DATABASE:-tablelite_dev}"
PROFILE_CONNECTION_ID="11111111-1111-1111-1111-111111111111"

profile_die() {
    echo "错误：$*" >&2
    exit 1
}

# 危险路径 / suite 的护栏：脚本这一半有 `rm -rf` 与 `defaults delete`，必须自己再校验一次
# （App 侧有等价校验，见 `DevLaunchOptions.validateDataDirectory`）。
profile_assert_safe() {
    python3 - "$PROFILE_DIR" "$PROFILE_SUITE" "$HOME" "$PROFILE_LIVE_ROOT" "$PROFILE_MAIN_SUITE" <<'SAFE_CHECK'
import os
import sys

path, suite, home, live, main_suite = sys.argv[1:6]
path = os.path.realpath(os.path.expanduser(path))
home = os.path.realpath(os.path.expanduser(home))
live = os.path.realpath(os.path.expanduser(live))


def is_ancestor(ancestor, target):
    a = ancestor.split(os.sep)
    b = target.split(os.sep)
    return len(a) <= len(b) and b[: len(a)] == a


if not path or path == os.sep or is_ancestor(path, home) or is_ancestor(live, path):
    print(f"拒绝：{path} 指向系统根 / 真实数据区（或它们的祖先）", file=sys.stderr)
    sys.exit(2)
if not suite.strip() or suite == main_suite:
    print(f"拒绝：偏好 suite「{suite}」为空或等于主域", file=sys.stderr)
    sys.exit(2)
looks_like_profile = (
    not os.path.exists(path)
    or not os.listdir(path)
    or os.path.exists(os.path.join(path, "app.pid"))
    or os.path.exists(os.path.join(path, "connections.json"))
)
if not looks_like_profile:
    print(f"拒绝：{path} 已存在且不像调试 profile（无 app.pid / connections.json），不删", file=sys.stderr)
    sys.exit(3)
SAFE_CHECK
}

# 只认我们自己启动的进程：PID 会被系统复用，光 `kill -0` 可能指向无关进程。
# 身份 = 可执行路径 + `--dev-data-dir`（见 `15-testing.md` §9.7）。
profile_pid() {
    if [[ -f "$PROFILE_PID_FILE" ]]; then
        local pid command_line
        pid="$(cat "$PROFILE_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
            if [[ "$command_line" == *"$PROFILE_APP"* && "$command_line" == *"--dev-data-dir"* ]]; then
                echo "$pid"
                return 0
            fi
        fi
        rm -f "$PROFILE_PID_FILE"
    fi
    return 1
}

profile_ensure_app() {
    [[ -x "$PROFILE_APP" ]] || profile_die "找不到 ${PROFILE_APP}，先 make build（或用 'tl.sh run --build …'）"
}

# 首次使用时写种子：连接 + 凭据 + 落盘 Console Log 的偏好。
# 用 python3 序列化而不是字符串拼接：密码里出现引号 / 反斜杠时拼出来的就是坏 JSON。
profile_ensure_seed() {
    profile_assert_safe
    mkdir -p "$PROFILE_DIR"
    if [[ ! -f "$PROFILE_DIR/connections.json" ]]; then
        python3 - "$PROFILE_DIR/connections.json" "$PROFILE_CONNECTION_ID" \
            "$PROFILE_DB_HOST" "$PROFILE_DB_PORT" "$PROFILE_DB_USER" "$PROFILE_DB_NAME" <<'SEED_CONNECTIONS'
import json
import sys

target, connection_id, host, port, user, database = sys.argv[1:7]
payload = {
    "schemaVersion": 1,
    "connections": [{
        "id": connection_id,
        "name": "demo",
        "color": "blue",
        "isReadOnly": False,
        "mysql": {
            "host": host,
            "port": int(port),
            "user": user,
            "database": database,
            "charset": "utf8mb4",
            "useSSL": False,
            "skipCertificateVerification": False,
            "connectTimeout": 10,
            "queryTimeout": 300,
            "keepAlive": False,
            "keepAliveInterval": 30,
        },
        "ssh": {
            "enabled": False,
            "host": "",
            "port": 22,
            "user": "",
            "authMethod": "sshConfigOrAgent",
            "useSSHConfigAlias": False,
        },
        "createdAt": 0,
        "updatedAt": 0,
    }],
}
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False)
SEED_CONNECTIONS
        chmod 600 "$PROFILE_DIR/connections.json"
    fi
    if [[ ! -f "$PROFILE_DIR/credentials.json" ]]; then
        python3 - "$PROFILE_DIR/credentials.json" "$PROFILE_CONNECTION_ID" "$PROFILE_DB_PASSWORD" <<'SEED_CREDENTIALS'
import json
import sys

target, connection_id, password = sys.argv[1:4]
payload = {"schemaVersion": 1, "entries": {connection_id: {"mysqlPassword": password}}}
with open(target, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False)
SEED_CREDENTIALS
        chmod 600 "$PROFILE_DIR/credentials.json"
    fi
    # 调试时 agent 要能读 SQL 与服务器错误（Q7 选 A：不新增日志 sink）。
    defaults write "$PROFILE_SUITE" "consoleLog.writeToFile" -bool true >/dev/null 2>&1 || true
}

# 只结束调试实例：按 PID（带身份校验），绝不 pkill（真实实例同 bundle id）。
# 返回 0 表示确实结束了一个进程；1 表示本来就没有在跑。
profile_quit() {
    local pid
    pid="$(profile_pid)" || return 1
    local axctl="$PROFILE_ROOT/.build/tools/axctl"
    if [[ -x "$axctl" ]]; then
        # 先按 PID 发退出（走真实退出流程，未提交改动的确认框有机会走完）。
        "$axctl" terminate --pid "$pid" >/dev/null 2>&1 || true
    fi
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.25
        done
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PROFILE_PID_FILE"
    return 0
}

profile_reset() {
    profile_assert_safe
    profile_quit || true
    rm -rf "$PROFILE_DIR"
    defaults delete "$PROFILE_SUITE" >/dev/null 2>&1 || true
    # 窗口 frame 的 autosave 名带 `-dev` 后缀，写的是标准域（S51 的例外项），要单独清。
    defaults delete "$PROFILE_MAIN_SUITE" "NSWindow Frame TableLite.MainWindow-dev" >/dev/null 2>&1 || true
    echo "已重置隔离 profile：${PROFILE_DIR}（suite ${PROFILE_SUITE}）"
}
