#!/bin/bash
# 截取 TableLite 主窗口，供 Agent 读图自查视觉回归（docs/tech-designs/15-testing.md §8.3）。
#
# 用法：scripts/dev/shot.sh [输出路径=/tmp/tablelite-shot.png]
# 注意：截图内容受「屏幕录制」权限控制，调用方进程（终端）需要已授权。
set -euo pipefail

OUT="${1:-/tmp/tablelite-shot.png}"

WID=$(/usr/bin/swift -e '
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "TableLite" && (w["kCGWindowLayer"] as? Int) == 0 {
    print(w["kCGWindowNumber"] as! Int)
    break
}')
if [ -z "${WID}" ]; then
    echo "找不到 TableLite 窗口（App 没在运行？）" >&2
    exit 1
fi

screencapture -x -l"${WID}" "${OUT}"
echo "${OUT}"
