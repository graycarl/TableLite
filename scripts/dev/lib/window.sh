#!/bin/bash
# 按 PID 定位调试实例的窗口（docs/tech-designs/15-testing.md §9.6）。
#
# 由 tl.sh source；不要单独执行。**禁止按 app 名找窗口**：真实实例与调试实例同名。

# 输出窗口 id（可能为空）。依赖 CSScreen 的 kCGWindowOwnerPID 过滤，见 axctl window。
window_id_for_pid() {
    local pid="$1"
    local json
    json="$(axctl_build >/dev/null 2>&1 && "$AXCTL_BIN" window --pid "$pid" 2>/dev/null)" || return 1
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(1)
windows = payload.get("windows") or []
print(windows[0]["id"] if windows else "")
'
}
