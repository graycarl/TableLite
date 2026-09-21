#!/usr/bin/env bash
# 硬约束：UI 层不得直接 import CMySQLClient。
#
# 依赖方向见 docs/tech-designs/01-architecture.md §1，
# 校验方式见 docs/tech-designs/15-testing.md §4。由 `make test` 调用。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI_DIR="$ROOT/Sources/TableLite/Features"

if [[ ! -d "$UI_DIR" ]]; then
  echo "  依赖方向检查跳过（还没有 Features 目录）"
  exit 0
fi

hits="$(grep -rn --include='*.swift' -E '^[[:space:]]*import[[:space:]]+CMySQLClient' "$UI_DIR" || true)"

if [[ -n "$hits" ]]; then
  echo "错误：UI 层不得直接 import CMySQLClient，数据库访问必须经过 MySQLSession / MetaRepository。" >&2
  echo "$hits" >&2
  exit 1
fi

echo "  依赖方向检查通过（UI 层未直接引用 CMySQLClient）"
