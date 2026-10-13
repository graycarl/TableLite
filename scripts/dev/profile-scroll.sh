#!/bin/bash
# 一键滚动卡顿录制：bench 自驱动 + Animation Hitches 录制 + 导出 + 清理。
# 见 docs/tech-designs/15-testing.md §8.2。
#
# 用法：scripts/dev/profile-scroll.sh [表名=wide_test] [基准时长秒=20]
# 前提：dev 库已启动（make db）、已构建（make build）。
set -euo pipefail

TABLE="${1:-wide_test}"
DUR="${2:-20}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${ROOT}/.build/Build/Products/Debug/TableLite.app/Contents/MacOS/TableLite"
OUT="/tmp/tl-profile-$(date +%H%M%S)"
LOG="${OUT}.bench.log"

if [ ! -x "${APP}" ]; then
    echo "找不到 ${APP}，先 make build" >&2
    exit 1
fi
if pgrep -xq TableLite; then
    echo "==> 退出正在运行的 TableLite"
    osascript -e 'tell application id "com.graycarl.tablelite" to quit' >/dev/null 2>&1 || true
    sleep 1
fi

echo "==> 启动基准（${TABLE}，${DUR}s）"
MYSQL_HOST=127.0.0.1 MYSQL_PORT=13307 MYSQL_USER=root MYSQL_PASSWORD=tablelite MYSQL_DATABASE=tablelite_dev \
    "${APP}" --bench-scroll "${TABLE}" --bench-duration "${DUR}" >"${LOG}" 2>&1 &
APP_PID=$!

# 等连接 + 加载 + 预热过去，再开始录制滚动阶段。
sleep 8
echo "==> 录制 Animation Hitches（${DUR}s）"
xctrace record --template "Animation Hitches" --attach TableLite \
    --time-limit "${DUR}s" --output "${OUT}.trace" || true
wait "${APP_PID}" || true

# xctrace 的原始 ktrace 中间文件不会自动清理，一次录制能留 10GB+
# （2026-10-08 六个残留文件吃掉 69GB 磁盘）——必须删。
rm -f "${TMPDIR%/}"/instruments*.ktrace

echo "== 基准输出 =="
grep '^{' "${LOG}" || cat "${LOG}"

# .trace 包要后台转换完才能导出，轮询等待。
for _ in $(seq 1 12); do
    xctrace export --input "${OUT}.trace" --toc >/dev/null 2>&1 && break
    sleep 5
done
xctrace export --input "${OUT}.trace" \
    --xpath "/trace-toc/run[@number='1']/data/table[@schema='hitches-frame-lifetimes']" \
    --output "${OUT}.frames.xml" || true
xctrace export --input "${OUT}.trace" \
    --xpath "/trace-toc/run[@number='1']/data/table[@schema='hitches']" \
    --output "${OUT}.hitches.xml" || true

echo "trace:  ${OUT}.trace"
echo "frames: ${OUT}.frames.xml"
echo "hitches: ${OUT}.hitches.xml"
