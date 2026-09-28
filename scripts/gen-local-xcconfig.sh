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

# ---- 部署目标：由依赖静态库的 minos 推导 ----
# 链接进 App 的每个 .a / dylib 都带自己的 minos，产物无法声称支持比它更低的系统，
# 取最大值即为下限。推导结果写进 Local.xcconfig 的 TABLELITE_DEPLOYMENT_TARGET，
# project.yml 用 $(TABLELITE_DEPLOYMENT_TARGET:default=…) 引用。
# 决策与理由见 docs/tech-designs/12-build-and-deps.md §3.3。
STATIC_LIBS=(
  "$MYSQL_CLIENT_PREFIX/lib/libmysqlclient.a"
  "$OPENSSL_PREFIX/lib/libssl.a"
  "$OPENSSL_PREFIX/lib/libcrypto.a"
  "$ZSTD_PREFIX/lib/libzstd.a"
  "$ZLIB_NG_PREFIX/lib/libz.a"
)

# .a 缺失或读不出 minos 时的兜底值。写在这里而不是放任 project.yml 落回
# default=，是为了让回退跟其他机器相关配置一样看得见（下方会打印警告）。
FALLBACK_DEPLOYMENT_TARGET=26.0

# 打印单个静态库里出现的全部 minos（含 LC_VERSION_MIN_MACOSX 这种旧写法）
minos_of() {
  otool -l "$1" 2>/dev/null | awk '
    /cmd LC_BUILD_VERSION/      { f = 1; next }
    /cmd LC_VERSION_MIN_MACOSX/ { g = 1; next }
    f && /minos/                { print $2; f = 0 }
    g && /version/              { print $2; g = 0 }
  '
}

# 版本号比较：$1 > $2（按点分段数值比较，macOS 的 sort 没有 -V）
version_gt() {
  [[ "$1" != "$2" ]] && \
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n | tail -1)" == "$1" ]]
}

# 截到 major.minor，缺 minor 时补 0。`.` 分段的比较必须两边段数一致，
# 否则 "27" 与 "27.0" 会被判成前者小（而不是相等）。
major_minor() {
  local major="${1%%.*}" minor="${1#*.}"
  [[ "$minor" == "$1" ]] && minor=0          # 没有点，说明只有 major
  minor="${minor%%.*}"
  printf '%s.%s' "$major" "$minor"
}

DEPLOYMENT_TARGET=""
for lib in "${STATIC_LIBS[@]}"; do
  [[ -f "$lib" ]] || continue
  while read -r version; do
    [[ -n "$version" ]] || continue
    DEPLOYMENT_TARGET="$(printf '%s\n%s\n' "${DEPLOYMENT_TARGET:-0}" "$version" \
      | sort -t. -k1,1n -k2,2n | tail -1)"
  done < <(minos_of "$lib")
done

MACOS_VERSION="$(sw_vers -productVersion)"

if [[ -z "$DEPLOYMENT_TARGET" ]]; then
  echo "警告：读不出依赖静态库的 minos，部署目标回退到 $FALLBACK_DEPLOYMENT_TARGET" >&2
  echo "      （先跑 make deps 看依赖是否齐全）" >&2
  DEPLOYMENT_TARGET="$FALLBACK_DEPLOYMENT_TARGET"
# 只比 major.minor：minos 只写到两位，sw_vers 给的是 major.minor.patch。
# 早先写的是 ${MACOS_VERSION%.*}，在 "27.0" 这种只有两个点时会把 minor 也砍掉（→ "27"），
# 于是本机与依赖同版本也误报「跑不起来」。
elif version_gt "$(major_minor "$DEPLOYMENT_TARGET")" "$(major_minor "$MACOS_VERSION")"; then
  # 把声明调小是没用的：库要求的 minos 不会跟着变小。
  # 变量一律加花括号：macOS 自带 bash 3.2 会把紧跟变量的多字节字符吞进变量名
  # （`$DEPLOYMENT_TARGET，` 会被解析成名为 `DEPLOYMENT_TARGET，` 的变量），配 set -u 直接报错。
  echo "警告：依赖静态库要求 macOS ${DEPLOYMENT_TARGET}，本机是 macOS ${MACOS_VERSION} ——" >&2
  echo "      构建出的 App 在本机跑不起来（会被 LaunchServices 拒开）。" >&2
  echo "      处理：brew reinstall mysql-client openssl@3 zstd zlib-ng-compat 装回与本机匹配的 bottle，" >&2
  echo "      或者升级 macOS 后重跑 make deps。" >&2
fi

TMP="$(mktemp)"
cat > "$TMP" <<EOF
// 由 scripts/gen-local-xcconfig.sh 生成，请勿手工修改，也不要提交到版本控制。
// 修改后重新执行：make deps

MYSQL_CLIENT_PREFIX = $MYSQL_CLIENT_PREFIX
OPENSSL_PREFIX = $OPENSSL_PREFIX
ZSTD_PREFIX = $ZSTD_PREFIX
ZLIB_NG_PREFIX = $ZLIB_NG_PREFIX
// 部署目标下限 = 上面这些静态库中最大的 minos（由本脚本推导，不要手工改）：
TABLELITE_DEPLOYMENT_TARGET = $DEPLOYMENT_TARGET
EOF

# 本机自签名签名身份（由 scripts/dev/codesign-identity.sh 建于登录钥匙串）。
# 装上就用它签名，让代码身份（designated requirement）跨构建稳定；没装就不写，
# project.yml 的 $(TABLELITE_CODESIGN_IDENTITY:default=-) 落到 ad-hoc 签名。
# 注意：它不能让登录钥匙串的授权跨构建有效（凭据已移出钥匙串）。
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
