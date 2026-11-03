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

profile_pid() {
    if [[ -f "$PROFILE_PID_FILE" ]]; then
        local pid
        pid="$(cat "$PROFILE_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    return 1
}

profile_ensure_app() {
    [[ -x "$PROFILE_APP" ]] || profile_die "找不到 ${PROFILE_APP}，先 make build（或用 'tl.sh run --build …'）"
}

# 首次使用时写种子：连接 + 凭据 + 落盘 Console Log 的偏好。
profile_ensure_seed() {
    mkdir -p "$PROFILE_DIR"
    if [[ ! -f "$PROFILE_DIR/connections.json" ]]; then
        cat > "$PROFILE_DIR/connections.json" <<EOF
{"schemaVersion":1,"connections":[{"id":"$PROFILE_CONNECTION_ID","name":"demo","color":"blue","isReadOnly":false,"mysql":{"host":"$PROFILE_DB_HOST","port":$PROFILE_DB_PORT,"user":"$PROFILE_DB_USER","database":"$PROFILE_DB_NAME","charset":"utf8mb4","useSSL":false,"skipCertificateVerification":false,"connectTimeout":10,"queryTimeout":300,"keepAlive":false,"keepAliveInterval":30},"ssh":{"enabled":false,"host":"","port":22,"user":"","authMethod":"sshConfigOrAgent","useSSHConfigAlias":false},"createdAt":0,"updatedAt":0}]}
EOF
        chmod 600 "$PROFILE_DIR/connections.json"
    fi
    if [[ ! -f "$PROFILE_DIR/credentials.json" ]]; then
        cat > "$PROFILE_DIR/credentials.json" <<EOF
{"schemaVersion":1,"entries":{"$PROFILE_CONNECTION_ID":{"mysqlPassword":"$PROFILE_DB_PASSWORD"}}}
EOF
        chmod 600 "$PROFILE_DIR/credentials.json"
    fi
    # 调试时 agent 要能读 SQL 与服务器错误（Q7 选 A：不新增日志 sink）。
    defaults write "$PROFILE_SUITE" "consoleLog.writeToFile" -bool true >/dev/null 2>&1 || true
}

# 只结束调试实例：按 PID，绝不 pkill（真实实例同 bundle id）。
profile_quit() {
    local pid
    pid="$(profile_pid)" || return 0
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
}

profile_reset() {
    profile_quit
    rm -rf "$PROFILE_DIR"
    defaults delete "$PROFILE_SUITE" >/dev/null 2>&1 || true
    echo "已重置隔离 profile：${PROFILE_DIR}（suite ${PROFILE_SUITE}）"
}
