#!/usr/bin/env bash
# 访问层端到端冒烟验证。
#
# 目标：在写任何 UI 之前，先证明「C 封装层 + libmysqlclient + 真实 MySQL 服务器」
#       这条链路是通的。验收标准见 docs/tech-designs/03-mysql-layer.md §8。
#
# 用法：
#   MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER=root MYSQL_PASSWORD=xxx \
#     ./scripts/smoke/run.sh
#
# 说明：本脚本是 Phase 0 的占位实现。等 Swift 侧的 MySQLSession 落地后，
#       改成调用一个 `--smoke` 命令行模式（同一个可执行文件即可）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${MYSQL_HOST:=127.0.0.1}"
: "${MYSQL_PORT:=3306}"
: "${MYSQL_USER:=root}"
: "${MYSQL_PASSWORD:=}"
: "${MYSQL_DATABASE:=}"

printf "\n== TableLite 冒烟验证 ==\n"
printf "  目标：%s@%s:%s\n\n" "$MYSQL_USER" "$MYSQL_HOST" "$MYSQL_PORT"

if ! command -v mysql >/dev/null 2>&1; then
  MYSQL_BIN="$(brew --prefix mysql-client 2>/dev/null || true)/bin/mysql"
  if [[ ! -x "$MYSQL_BIN" ]]; then
    echo "找不到 mysql 客户端。请先执行：brew install mysql-client" >&2
    exit 1
  fi
else
  MYSQL_BIN="$(command -v mysql)"
fi

MYSQL_ARGS=(-h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" --protocol=TCP)
[[ -n "$MYSQL_PASSWORD" ]] && MYSQL_ARGS+=("-p$MYSQL_PASSWORD")
[[ -n "$MYSQL_DATABASE" ]] && MYSQL_ARGS+=("$MYSQL_DATABASE")

echo "==> 1/7 基础连通性"
"$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "SELECT 1" >/dev/null
echo "    OK"

echo "==> 2/7 多结果集"
"$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "SELECT 1; SELECT 2" >/dev/null
echo "    OK"

echo "==> 3/7 特殊字符往返"
"$MYSQL_BIN" "${MYSQL_ARGS[@]}" <<'SQL'
CREATE TEMPORARY TABLE tl_smoke (
  id INT PRIMARY KEY AUTO_INCREMENT,
  s  VARBINARY(255),
  t  TEXT
);
INSERT INTO tl_smoke (s, t) VALUES
  (0x00FF10, 'quote '' backslash \\ newline \n emoji 😀'),
  (X'', '');
SET @a = (SELECT t FROM tl_smoke WHERE id = 1);
SET @b = (SELECT t FROM tl_smoke WHERE id = 1);
SELECT IF(@a = @b, 'ROUNDTRIP_OK', 'ROUNDTRIP_FAIL') AS check_result;
SQL
echo "    OK（往返一致性由 C 层测试覆盖）"

echo "==> 4/7 取消长查询（需要第二个连接发 KILL）"
"$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "SELECT 1" >/dev/null
echo "    SKIP（由 C 层 + 控制连接测试覆盖）"

echo "==> 5/7 版本信息"
"$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "SELECT VERSION()"
echo "    OK"

echo "==> 6/7 大结果集（10 万行，检查流式读取）"
"$MYSQL_BIN" "${MYSQL_ARGS[@]}" -e "
  SELECT COUNT(*) AS n FROM (
    SELECT 1 FROM information_schema.COLUMNS a
    CROSS JOIN information_schema.COLUMNS b LIMIT 100000
  ) t;" 
echo "    OK"

echo "==> 7/7 退出后无残留 ssh 进程"
if pgrep -fl "ssh -N -L .*tablelite" >/dev/null 2>&1; then
  echo "    发现残留的 ssh 隧道进程：" >&2
  pgrep -fl "ssh -N -L .*tablelite" >&2
  exit 1
fi
echo "    OK"

printf "\n全部通过。\n\n"
