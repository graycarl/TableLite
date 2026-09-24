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
ZLIB_NG_PREFIX="$(brew --prefix zlib-ng-compat 2>/dev/null || true)"

if [[ -z "$MYSQL_CLIENT_PREFIX" ]]; then
  echo "错误：mysql-client 未安装。请先执行：brew install mysql-client" >&2
  exit 1
fi

# 依赖缺失时退化为 Homebrew 的 opt 路径，构建阶段会给出更明确的报错
: "${OPENSSL_PREFIX:=$(brew --prefix)/opt/openssl@3}"
: "${ZSTD_PREFIX:=$(brew --prefix)/opt/zstd}"
: "${ZLIB_NG_PREFIX:=$(brew --prefix)/opt/zlib-ng-compat}"

TMP="$(mktemp)"
cat > "$TMP" <<EOF
// 由 scripts/gen-local-xcconfig.sh 生成，请勿手工修改，也不要提交到版本控制。
// 修改后重新执行：make deps

MYSQL_CLIENT_PREFIX = $MYSQL_CLIENT_PREFIX
OPENSSL_PREFIX = $OPENSSL_PREFIX
ZSTD_PREFIX = $ZSTD_PREFIX
ZLIB_NG_PREFIX = $ZLIB_NG_PREFIX
EOF

# 本机自签名签名身份（由 scripts/dev/codesign-identity.sh 建于登录钥匙串）。
# 装上就用它签名，让 Keychain 的「始终允许」授权跨构建有效；没装就不写，
# project.yml 的 $(TABLELITE_CODESIGN_IDENTITY:default=-) 落到 ad-hoc 签名。
# 见 docs/tech-designs/12-build-and-deps.md §3.4。
CODESIGN_IDENTITY="${TABLELITE_CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null \
     | grep -q '"TableLite Local Dev"'; then
  CODESIGN_IDENTITY="TableLite Local Dev"
fi
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  printf 'TABLELITE_CODESIGN_IDENTITY = %s\n' "$CODESIGN_IDENTITY" >> "$TMP"
fi

mkdir -p "$(dirname "$OUT")"

if [[ -f "$OUT" ]] && cmp -s "$TMP" "$OUT"; then
  rm -f "$TMP"
  echo "  Configs/Local.xcconfig 无变化"
else
  mv "$TMP" "$OUT"
  echo "  已写入 Configs/Local.xcconfig"
  sed 's/^/    /' "$OUT"
fi
