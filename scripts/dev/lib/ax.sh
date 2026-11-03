#!/bin/bash
# axctl 的编译缓存与调用包装（docs/tech-designs/15-testing.md §9.4）。
#
# 由 tl.sh source；不要单独执行。

AXCTL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AXCTL_SOURCE="$AXCTL_ROOT/scripts/dev/axctl.swift"
AXCTL_BIN="$AXCTL_ROOT/.build/tools/axctl"

# 源码比二进制新才重编（一次约 4s，之后调用 ~0.05s）。
axctl_build() {
    if [[ -x "$AXCTL_BIN" && "$AXCTL_BIN" -nt "$AXCTL_SOURCE" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "$AXCTL_BIN")"
    if ! /usr/bin/swiftc -O "$AXCTL_SOURCE" -o "$AXCTL_BIN" 2>&1; then
        echo "错误：axctl 编译失败" >&2
        return 1
    fi
}

# 调用 axctl；已有调试实例时自动补 --pid（显式传了就不再注入）。
axctl_run() {
    axctl_build || return 1
    if [[ "$*" == *"--pid"* ]] || [[ "${1:-}" == "help" ]] || [[ -z "${1:-}" ]]; then
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
