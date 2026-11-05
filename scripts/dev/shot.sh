#!/bin/bash
# 截取调试实例的窗口，供 Agent 读图自查视觉回归（docs/tech-designs/15-testing.md §9.6）。
#
# 用法：scripts/dev/shot.sh [输出路径=/tmp/tablelite-shot.png] [--width 像素]
#
# 现在只是 tl.sh shot 的薄壳：**按 PID** 找调试实例窗口
# （`screencapture -l` 需要屏幕录制权限；`.build/tools/axctl` 提供窗口 id）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ $# -eq 0 ]]; then
    exec "$ROOT/scripts/dev/tl.sh" shot /tmp/tablelite-shot.png
fi
exec "$ROOT/scripts/dev/tl.sh" shot "$@"
