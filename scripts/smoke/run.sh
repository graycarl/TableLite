#!/usr/bin/env bash
# 访问层端到端冒烟验证。
#
# 目标：在写任何 UI 之前，先证明「C 封装层 + libmysqlclient + 真实 MySQL 服务器」
#       这条链路是通的。验收标准见 docs/tech-designs/03-mysql-layer.md §8。
#
# 7 项验证由 App 可执行文件的 `--smoke` 模式完成（同一个二进制，见
# Sources/TableLite/Core/MySQL/SmokeRunner.swift），本脚本只负责准备和清理数据库。
#
# 用法：
#   make smoke                      # 自动起一个 Docker MySQL（默认端口 13306）
#   make smoke SMOKE_KEEP=1         # 跑完保留容器，便于手工排查
#   MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER=root MYSQL_PASSWORD=xxx \
#     ./scripts/smoke/run.sh        # 用已有服务器，完全不碰 Docker
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT/scripts/smoke/docker-compose.yml"
PROJECT_NAME="tablelite-smoke"
BINARY="${SMOKE_BINARY:-$ROOT/.build/Build/Products/Debug/TableLite.app/Contents/MacOS/TableLite}"

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'

if [[ ! -x "$BINARY" ]]; then
  printf "${RED}找不到可执行文件：${RESET}%s\n" "$BINARY" >&2
  printf "请先执行：make build\n" >&2
  exit 1
fi

# ---------------------------------------------------------------- 用已有服务器
started_container=0
if [[ -n "${MYSQL_HOST:-}" ]]; then
  : "${MYSQL_PORT:=3306}"
  : "${MYSQL_USER:=root}"
  : "${MYSQL_PASSWORD:=}"
  printf "${DIM}使用已有服务器 %s@%s:%s，不启动 Docker。${RESET}\n" "$MYSQL_USER" "$MYSQL_HOST" "$MYSQL_PORT"
else
  # ------------------------------------------------------------ 起 Docker MySQL
  if command -v docker-compose >/dev/null 2>&1; then
    compose() { docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"; }
  elif docker compose version >/dev/null 2>&1; then
    compose() { docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"; }
  else
    printf "${RED}找不到 docker-compose。${RESET}\n" >&2
    printf "可以装：brew install docker-compose，或者用 MYSQL_HOST=... 指向已有的 MySQL。\n" >&2
    exit 1
  fi

  cleanup() {
    if [[ "$started_container" == "1" && "${SMOKE_KEEP:-0}" != "1" ]]; then
      printf "\n${DIM}清理容器…${RESET}\n"
      compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    elif [[ "$started_container" == "1" ]]; then
      printf "\n${DIM}SMOKE_KEEP=1，保留容器：%s${RESET}\n" "$PROJECT_NAME"
    fi
  }
  trap cleanup EXIT

  : "${SMOKE_MYSQL_PORT:=13306}"
  export SMOKE_MYSQL_PORT
  MYSQL_HOST=127.0.0.1
  MYSQL_PORT="$SMOKE_MYSQL_PORT"
  MYSQL_USER=root
  MYSQL_PASSWORD=tablelite

  printf "${DIM}启动 Docker MySQL (mysql:8.4) 于 127.0.0.1:%s …${RESET}\n" "$MYSQL_PORT"
  compose up -d --wait --wait-timeout 180
  started_container=1
fi

# ---------------------------------------------------------------- 跑验证
printf "\n"
set +e
MYSQL_HOST="$MYSQL_HOST" \
MYSQL_PORT="$MYSQL_PORT" \
MYSQL_USER="$MYSQL_USER" \
MYSQL_PASSWORD="$MYSQL_PASSWORD" \
MYSQL_DATABASE="${MYSQL_DATABASE:-tablelite_smoke}" \
  "$BINARY" --smoke
status=$?
set -e

if [[ $status -eq 0 ]]; then
  printf "\n${GREEN}冒烟验证通过。${RESET}\n"
  # -------------------------------------------------------------- 编辑链路
  if [[ "${SMOKE_EDIT:-1}" == "1" ]]; then
    printf "\n${DIM}编辑链路端到端（--edit-smoke）：字段栏 → 暂存 → 预览 → 提交 …${RESET}\n"
    set +e
    MYSQL_HOST="$MYSQL_HOST" \
    MYSQL_PORT="$MYSQL_PORT" \
    MYSQL_USER="$MYSQL_USER" \
    MYSQL_PASSWORD="$MYSQL_PASSWORD" \
    MYSQL_DATABASE="${MYSQL_DATABASE:-tablelite_smoke}" \
      "$BINARY" --edit-smoke
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      printf "\n${GREEN}编辑冒烟验证通过。${RESET}\n"
    else
      printf "\n${RED}编辑冒烟验证失败（退出码 %d）。${RESET}\n" "$status"
    fi
  fi
  # -------------------------------------------------------------- 过滤链路
  if [[ "${SMOKE_FILTER:-1}" == "1" ]]; then
    printf "\n${DIM}过滤链路端到端（--filter-smoke）：行过滤器 / 条件叠加 / Raw / 列显隐 …${RESET}\n"
    set +e
    MYSQL_HOST="$MYSQL_HOST" \
    MYSQL_PORT="$MYSQL_PORT" \
    MYSQL_USER="$MYSQL_USER" \
    MYSQL_PASSWORD="$MYSQL_PASSWORD" \
    MYSQL_DATABASE="${MYSQL_DATABASE:-tablelite_smoke}" \
      "$BINARY" --filter-smoke
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      printf "\n${GREEN}过滤冒烟验证通过。${RESET}\n"
    else
      printf "\n${RED}过滤冒烟验证失败（退出码 %d）。${RESET}\n" "$status"
    fi
  fi
  # -------------------------------------------------------------- 查询编辑器链路
  if [[ "${SMOKE_QUERY:-1}" == "1" ]]; then
    printf "\n${DIM}查询编辑器端到端（--query-smoke）：多语句 / 错误 / 只读 / 取消 / 记录 …${RESET}\n"
    set +e
    MYSQL_HOST="$MYSQL_HOST" \
    MYSQL_PORT="$MYSQL_PORT" \
    MYSQL_USER="$MYSQL_USER" \
    MYSQL_PASSWORD="$MYSQL_PASSWORD" \
    MYSQL_DATABASE="${MYSQL_DATABASE:-tablelite_smoke}" \
      "$BINARY" --query-smoke
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      printf "\n${GREEN}查询编辑器冒烟验证通过。${RESET}\n"
    else
      printf "\n${RED}查询编辑器冒烟验证失败（退出码 %d）。${RESET}\n" "$status"
    fi
  fi
else
  printf "\n${RED}冒烟验证失败（退出码 %d）。${RESET}\n" "$status"
fi
exit $status
