#!/usr/bin/env bash
# 生成 Configs/Local.xcconfig —— 把机器相关的 Homebrew 路径集中到一处。
# 该文件不进版本控制；内容未变化时不重写，避免触发无谓的重新构建。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Configs/Local.xcconfig"

if ! command -v brew >/dev/null 2>&1; then
  echo "错误：找不到 brew，无法解析依赖路径。" >&2
  exit 1
fi

MYSQL_CLIENT_PREFIX="$(brew --prefix mysql-client 2>/dev/null || true)"
OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
ZSTD_PREFIX="$(brew --prefix zstd 2>/dev/null || true)"

if [[ -z "$MYSQL_CLIENT_PREFIX" ]]; then
  echo "错误：mysql-client 未安装。请先执行：brew install mysql-client" >&2
  exit 1
fi

# 依赖缺失时退化为 Homebrew 的 opt 路径，构建阶段会给出更明确的报错
: "${OPENSSL_PREFIX:=$(brew --prefix)/opt/openssl@3}"
: "${ZSTD_PREFIX:=$(brew --prefix)/opt/zstd}"

TMP="$(mktemp)"
cat > "$TMP" <<EOF
// 由 scripts/gen-local-xcconfig.sh 生成，请勿手工修改，也不要提交到版本控制。
// 修改后重新执行：make deps

MYSQL_CLIENT_PREFIX = $MYSQL_CLIENT_PREFIX
OPENSSL_PREFIX = $OPENSSL_PREFIX
ZSTD_PREFIX = $ZSTD_PREFIX
EOF

mkdir -p "$(dirname "$OUT")"

if [[ -f "$OUT" ]] && cmp -s "$TMP" "$OUT"; then
  rm -f "$TMP"
  echo "  Configs/Local.xcconfig 无变化"
else
  mv "$TMP" "$OUT"
  echo "  已写入 Configs/Local.xcconfig"
  sed 's/^/    /' "$OUT"
fi
