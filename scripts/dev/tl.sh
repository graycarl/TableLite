#!/bin/bash
# Agent 自测的统一入口（docs/tech-designs/15-testing.md §9.7）。
#
#   tl.sh run [--build] [--dev-* ...]   起隔离实例并等到 ready
#   tl.sh reset                         清空隔离 profile（数据目录 + dev 偏好 suite）
#   tl.sh quit                          只退出调试实例（按 PID）
#   tl.sh shot [输出路径] [--width N]   截调试实例窗口
#   tl.sh ax <子命令…>                   AX 驱动（见 tl.sh ax help）
#   tl.sh cell <行>,<列>                读单元格文本与位置
#   tl.sh logs [--since 2m] [--grep RE] 合并三源日志
#   tl.sh doctor                        检查权限 / 构建 / 数据库 / 工具
#   tl.sh selftest                      调试基建自检（关键 identifier + 网格寻址）
set -uo pipefail

TL_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$TL_ROOT/scripts/dev/lib/profile.sh"
source "$TL_ROOT/scripts/dev/lib/ax.sh"
source "$TL_ROOT/scripts/dev/lib/window.sh"

set -e

usage() {
    cat <<'EOF'
用法：
  tl.sh run [--build] [--dev-* ...]   起隔离实例并等到 ready
  tl.sh reset                         清空隔离 profile（数据目录 + dev 偏好 suite）
  tl.sh quit                          只退出调试实例（按 PID）
  tl.sh shot [输出路径] [--width N]   截调试实例窗口
  tl.sh ax <子命令…>                   AX 驱动（tl.sh ax help 看用法）
  tl.sh cell <行>,<列>                读单元格文本与位置
  tl.sh logs [--since 2m] [--grep RE] 合并三源日志
  tl.sh doctor                        检查权限 / 构建 / 数据库 / 工具
  tl.sh selftest                      调试基建自检
EOF
}

require_pid() {
    profile_pid || profile_die "调试实例没在跑（先 tl.sh run …）"
}

cmd_run() {
    local build=0
    local passthrough=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build) build=1; shift ;;
            --) shift; passthrough+=("$@"); break ;;
            *) passthrough+=("$1"); shift ;;
        esac
    done
    if [[ $build -eq 1 ]]; then
        make -C "$TL_ROOT" build
    fi
    # 隔离目录 / suite / ready 文件由脚本统一管理，别让调用方覆盖（会读错 ready 文件）。
    local arg
    for arg in ${passthrough[@]+"${passthrough[@]}"}; do
        case "$arg" in
            --dev-data-dir | --dev-defaults-suite | --dev-ready-file)
                profile_die "$arg 由 tl.sh 管理，不要自己传"
                ;;
        esac
    done
    profile_ensure_app
    profile_ensure_seed
    profile_quit
    rm -f "$PROFILE_READY"
    : > "$PROFILE_LOG"

    # 必须 exec：否则记录的是包一层的子 shell，退出时按 PID 找不到真正的 app 进程。
    (
        cd "$TL_ROOT" || exit 1
        exec nohup "$PROFILE_APP" \
            --dev-data-dir "$PROFILE_DIR" \
            --dev-defaults-suite "$PROFILE_SUITE" \
            --dev-ready-file "$PROFILE_READY" \
            ${passthrough[@]+"${passthrough[@]}"} >> "$PROFILE_LOG" 2>&1
    ) &
    echo $! > "$PROFILE_PID_FILE"

    local pid
    pid="$(cat "$PROFILE_PID_FILE")"
    echo "调试实例 pid=$pid data=$PROFILE_DIR suite=$PROFILE_SUITE" >&2

    local waited=0
    while [[ $waited -lt 90 ]]; do
        if [[ -s "$PROFILE_READY" ]]; then
            cat "$PROFILE_READY"
            echo
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "错误：调试实例启动后退出了，最近日志：" >&2
            tail -n 40 "$PROFILE_LOG" >&2
            return 1
        fi
        sleep 0.25
        waited=$((waited + 1))
    done
    echo "错误：等待 ready 超时（90s），最近日志：" >&2
    tail -n 40 "$PROFILE_LOG" >&2
    return 1
}

cmd_reset() {
    profile_reset
}

cmd_quit() {
    profile_quit
    echo "调试实例已退出（真实实例不受影响）"
}

cmd_shot() {
    local out="/tmp/tablelite-dev.png"
    local width=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --width) width="$2"; shift 2 ;;
            *) out="$1"; shift ;;
        esac
    done
    local pid
    pid="$(require_pid)"
    local wid
    wid="$(window_id_for_pid "$pid")"
    [[ -n "$wid" ]] || profile_die "找不到调试实例的窗口（窗口是否已关闭？）"
    screencapture -x -o -l"$wid" "$out"
    if [[ -n "$width" ]]; then
        sips --resampleWidth "$width" "$out" >/dev/null
    fi
    echo "$out"
}

cmd_ax() {
    axctl_run "$@"
}

cmd_cell() {
    local spec="${1:-}"
    [[ -n "$spec" ]] || profile_die "用法：tl.sh cell <行>,<列>"
    local row="${spec%%,*}"
    local column="${spec#*,}"
    axctl_run cell --row "$row" --column "$column"
}

cmd_logs() {
    local since="2m"
    local pattern=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since) since="$2"; shift 2 ;;
            --grep) pattern="$2"; shift 2 ;;
            *) profile_die "未知参数 $1" ;;
        esac
    done

    apply_filter() {
        if [[ -n "$pattern" ]]; then
            grep -E -- "$pattern" || true
        else
            cat
        fi
    }

    echo "== app stdout（${PROFILE_LOG}） =="
    if [[ -f "$PROFILE_LOG" ]]; then
        tail -n 300 "$PROFILE_LOG" | apply_filter
    else
        echo "（没有日志：调试实例还没跑过）"
    fi

    echo
    echo "== Console Log（SQL / 服务器错误） =="
    local console_dir="$PROFILE_DIR/ConsoleLogs"
    if compgen -G "$console_dir/*.log" >/dev/null; then
        tail -n 300 "$console_dir"/*.log | apply_filter
    else
        echo "（没有落盘文件：检查 dev suite 的 consoleLog.writeToFile）"
    fi

    echo
    echo "== StoreLog（OSLog，最近 ${since}） =="
    log show --style compact --info --debug --last "$since" \
        --predicate 'subsystem == "com.graycarl.tablelite"' 2>/dev/null | apply_filter
}

cmd_doctor() {
    local failed=0
    local mark_ok="✓"
    local mark_bad="✗"

    if [[ -x "$PROFILE_APP" ]]; then
        echo "  $mark_ok 调试产物：$PROFILE_APP"
    else
        echo "  $mark_bad 找不到调试产物（先 make build）"
        failed=1
    fi

    if axctl_build; then
        local trusted
        trusted="$("$AXCTL_BIN" doctor --pid $$ 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("accessibility"))' 2>/dev/null || echo False)"
        if [[ "$trusted" == "True" ]]; then
            echo "  $mark_ok 辅助功能权限"
        else
            echo "  $mark_bad 缺少辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能，给终端授权）"
            failed=1
        fi
    else
        echo "  $mark_bad axctl 编译失败"
        failed=1
    fi

    local shot
    shot="$(mktemp -t tl-doctor).png"
    if screencapture -x "$shot" 2>/dev/null && [[ -s "$shot" ]]; then
        echo "  $mark_ok 屏幕录制权限"
    else
        echo "  $mark_bad 缺少屏幕录制权限（系统设置 → 隐私与安全性 → 屏幕录制）"
        failed=1
    fi
    rm -f "$shot"

    if nc -G 1 -z "$PROFILE_DB_HOST" "$PROFILE_DB_PORT" 2>/dev/null; then
        echo "  $mark_ok dev MySQL $PROFILE_DB_HOST:$PROFILE_DB_PORT"
    else
        echo "  $mark_bad dev MySQL 不可达（make db）"
        failed=1
    fi

    if mkdir -p "$PROFILE_DIR" 2>/dev/null && [[ -w "$PROFILE_DIR" ]]; then
        echo "  $mark_ok 隔离目录可写：${PROFILE_DIR}（suite ${PROFILE_SUITE}）"
    else
        echo "  $mark_bad 隔离目录不可写：$PROFILE_DIR"
        failed=1
    fi

    if profile_pid >/dev/null; then
        echo "  ✓ 调试实例在跑：pid $(profile_pid)"
    else
        echo "  · 调试实例未运行"
    fi
    return $failed
}

cmd_selftest() {
    local script="$TL_ROOT/scripts/dev/selftest.sh"
    [[ -x "$script" ]] || profile_die "缺少 $script"
    "$script"
}

case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    reset) shift; cmd_reset ;;
    quit) shift; cmd_quit ;;
    shot) shift; cmd_shot "$@" ;;
    ax) shift; cmd_ax "$@" ;;
    cell) shift; cmd_cell "$@" ;;
    logs) shift; cmd_logs "$@" ;;
    doctor) shift; cmd_doctor ;;
    selftest) shift; cmd_selftest ;;
    help | -h | --help | "") usage ;;
    *) usage; exit 2 ;;
esac
