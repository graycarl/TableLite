#!/usr/bin/env bash
# 手工测试用的常驻 MySQL（用 scripts/dev/docker-compose.yml 起，与冒烟完全独立）。
#
# 与 `make smoke` 的区别：这个容器**不自动清理**，数据存在 volume 里，
# 可以反复用 App 连上去点点看；两者用不同的 compose 文件、容器名与端口，互不干扰。
#
# 用法：
#   ./scripts/dev/db.sh up      # 起容器（首次顺带灌示例数据）
#   ./scripts/dev/db.sh reset   # 删库重灌示例数据
#   ./scripts/dev/db.sh shell   # 进 mysql 客户端
#   ./scripts/dev/db.sh logs    # 看服务器日志
#   ./scripts/dev/db.sh down    # 停容器并删数据
#
# 连接参数（默认 127.0.0.1:13307，root/tablelite，库 tablelite_dev）。
# 端口默认 13307，与 `make smoke` 的 13306 错开，两个可以同时开着。
#   DEV_MYSQL_PORT=13308 ./scripts/dev/db.sh up
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT/scripts/dev/docker-compose.yml"
SEED_FILE="$ROOT/scripts/dev/seed.sql"
PROJECT_NAME="tablelite-dev"
CONTAINER_NAME="tablelite-dev-mysql"
DATABASE="${DEV_MYSQL_DATABASE:-tablelite_dev}"
PORT="${DEV_MYSQL_PORT:-13307}"

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'

if command -v docker-compose >/dev/null 2>&1; then
  compose() { docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"; }
elif docker compose version >/dev/null 2>&1; then
  compose() { docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"; }
else
  printf "${RED}找不到 docker-compose。${RESET}可以装：brew install docker-compose\n" >&2
  exit 1
fi

export DEV_MYSQL_PORT="$PORT"
HOST=127.0.0.1
USER=root
PASSWORD=tablelite

mysql_exec() { docker exec -i -e MYSQL_PWD="$PASSWORD" "$CONTAINER_NAME" mysql -uroot "$@"; }

seed() {
  printf "${DIM}灌入示例数据（%s）…${RESET}\n" "$DATABASE"
  mysql_exec < "$SEED_FILE"
  printf "${GREEN}示例数据就绪。${RESET}\n"
}

print_connection() {
  cat <<EOF

  在 TableLite 里新建连接：

    Host      $HOST
    Port      $PORT
    User      $USER
    Password  $PASSWORD
    Database  $DATABASE

  建表/改数据随便造，数据留在 Docker volume 里；
  想回到干净状态执行：make db-reset
EOF
}

cmd="${1:-up}"
case "$cmd" in
  up)
    printf "${DIM}启动 Docker MySQL (mysql:8.4) 于 %s:%s …${RESET}\n" "$HOST" "$PORT"
    compose up -d --wait --wait-timeout 180
    # 只在库不存在时灌数据，避免每次 up 都冲掉手工改出来的数据
    if [[ "$(mysql_exec -N -B -e "SHOW DATABASES LIKE '$DATABASE'")" != "$DATABASE" ]]; then
      seed
    else
      printf "${DIM}%s 已存在，跳过灌数据（要重灌用 make db-reset）。${RESET}\n" "$DATABASE"
    fi
    print_connection
    ;;
  reset)
    compose up -d --wait --wait-timeout 180
    seed
    print_connection
    ;;
  shell)
    exec docker exec -it -e MYSQL_PWD="$PASSWORD" "$CONTAINER_NAME" mysql -uroot "$DATABASE"
    ;;
  logs)
    compose logs -f mysql
    ;;
  down)
    compose down --volumes --remove-orphans
    printf "${GREEN}已停止并删除容器与数据。${RESET}\n"
    ;;
  *)
    printf "${RED}未知子命令：%s${RESET}\n" "$cmd" >&2
    printf "可用：up | reset | shell | logs | down\n" >&2
    exit 1
    ;;
esac
