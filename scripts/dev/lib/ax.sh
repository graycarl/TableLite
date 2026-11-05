#!/bin/bash
# axctl 的编译缓存与调用包装（docs/tech-designs/15-testing.md §9.4）。
#
# 由 tl.sh source；不要单独执行。

AXCTL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AXCTL_SOURCE="$AXCTL_ROOT/scripts/dev/axctl.swift"
AXCTL_BIN="$AXCTL_ROOT/.build/tools/axctl"

# 源码比二进制新才重编（一次约 4s，之后调用 ~0.1s）。
# 编译错误必须走 stderr：stdout 是 JSON，混进日志会让调用方解析失败。
axctl_build() {
    if [[ -x "$AXCTL_BIN" && "$AXCTL_BIN" -nt "$AXCTL_SOURCE" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$AXCTL_BIN")"
    if ! /usr/bin/swiftc -O "$AXCTL_SOURCE" -o "$AXCTL_BIN" 1>&2; then
        echo "错误：axctl 编译失败" >&2
        return 1
    fi
}

# 调用 axctl；已有调试实例时自动补 --pid（显式传了就不再注入）。
axctl_run() {
    axctl_build || return 1
    local argument has_pid=0
    for argument in "$@"; do
        if [[ "$argument" == "--pid" ]]; then
            has_pid=1
            break
        fi
    done
    if [[ $has_pid -eq 1 || "${1:-}" == "help" || -z "${1:-}" ]]; then
        "$AXCTL_BIN" "$@"
        return $?
    fi
    local pid
    if pid="$(profile_pid)"; then
        "$AXCTL_BIN" "$@" --pid "$pid"
    else
        "$AXCTL_BIN" "$@"
    fi
}
