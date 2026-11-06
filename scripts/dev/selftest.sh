#!/bin/bash
# 调试基建自检（docs/tech-designs/15-testing.md §9.7）。
#
# 断言三个代表性状态能走到、关键 identifier 在 AX 树里、网格能按 (row, column) 寻址、
# 交互能改到实际状态。identifier 随 UI 重构失效时这里必须变红。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TL="$ROOT/scripts/dev/tl.sh"

fail() {
    echo "  ✗ $*" >&2
    exit 1
}

expect_id() {
    local id="$1"
    "$TL" ax wait --id "$id" --timeout 10 >/dev/null 2>&1 || fail "AX 树里找不到 identifier：${id}"
    echo "  ✓ ${id}"
}

read_json() {
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',''))"
}

has_id() {
    "$TL" ax find --id "$1" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0) > 0)"
}

# 筛选面板 / 模式是标签现场的一部分（可能被 session.json 还原），脚本不能假设初始状态。
ensure_filter_panel() {
    if [[ "$(has_id filter.apply)" == "True" ]]; then return 0; fi
    "$TL" ax click --id grid.statusbar.filter >/dev/null
    expect_id filter.apply
}

ensure_raw_mode() {
    if [[ "$(has_id filter.raw-input)" == "True" ]]; then return 0; fi
    "$TL" ax press --id filter.mode-raw >/dev/null
    "$TL" ax wait --id filter.raw-input --timeout 5 >/dev/null 2>&1 \
        || fail "切到高级模式后找不到 filter.raw-input"
    echo "  ✓ 切到高级模式"
}

wait_cell_text() {
    local row="$1" column="$2" expected="$3"
    local value=""
    for _ in $(seq 1 40); do
        value="$("$TL" cell "$row,$column" | read_json text)"
        [[ "$value" == "$expected" ]] && return 0
        sleep 0.25
    done
    fail "cell ${row},${column} 期望「${expected}」，实际「${value}」"
}

# 后面两步依赖 dev 库里的种子数据（tablelite_dev.orders）。
if ! nc -G 1 -z "${MYSQL_HOST:-127.0.0.1}" "${MYSQL_PORT:-13307}" 2>/dev/null; then
    echo "  ✗ dev MySQL 不可达：先 make db（127.0.0.1:13307）" >&2
    exit 1
fi

echo "== 1/3 连接列表：隔离 profile 干净启动 =="
"$TL" reset >/dev/null
"$TL" run >/dev/null
expect_id connections.new
"$TL" shot /tmp/tablelite-selftest-1.png --width 1000 >/dev/null
echo "  截图：/tmp/tablelite-selftest-1.png"

echo "== 2/3 工作区：打开表、选中单元格 =="
"$TL" run --dev-open-connection demo --dev-open-table tablelite_dev.orders \
    --dev-select-cell 2,status >/dev/null
for id in grid.table grid.statusbar.filter grid.statusbar.row-limit tabs.bar sidebar.tree toolbar.connection-switcher toolbar.quick-open toolbar.refresh toolbar.inspector-toggle; do
    expect_id "$id"
done

text="$("$TL" cell 2,status | read_json text)"
[[ -n "$text" ]] || fail "cell 2,status 读不到文本"
echo "  ✓ cell 2,status = ${text}"
"$TL" shot /tmp/tablelite-selftest-2.png --width 1000 >/dev/null
echo "  截图：/tmp/tablelite-selftest-2.png"

echo "== 3/3 交互：打开筛选面板、输入条件并应用 =="
ensure_filter_panel
ensure_raw_mode
"$TL" ax type --id filter.raw-input --text "status = 'refunded'" >/dev/null
"$TL" ax click --id filter.apply >/dev/null
wait_cell_text 1 status refunded
echo "  ✓ 过滤生效（第 1 行 status = refunded）"
"$TL" shot /tmp/tablelite-selftest-3.png --width 1000 >/dev/null
echo "  截图：/tmp/tablelite-selftest-3.png"

# 自检同样要收尾：不留占着窗口的调试实例。
"$TL" quit >/dev/null 2>&1 || true

echo
echo "自检通过：3 个状态、关键 identifier、单元格寻址、过滤交互。"
echo "（截图留在 /tmp/tablelite-selftest-{1,2,3}.png）"
