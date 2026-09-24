#!/usr/bin/env bash
# 检查构建所需的外部依赖。缺失时给出可执行的修复命令并退出 1。
set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

fail=0
warn=0

ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
miss() { printf "  ${RED}✗${RESET} %s\n" "$1"; printf "      ${DIM}修复：%s${RESET}\n" "$2"; fail=1; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; warn=1; }

printf "\n== TableLite 依赖检查 ==\n\n"

# ---- Homebrew ----
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix)"
  ok "Homebrew ($BREW_PREFIX)"
else
  miss "Homebrew 未安装" "见 https://brew.sh/"
  printf "\n检查未通过。\n\n"
  exit 1
fi

# ---- Xcode / 命令行工具 ----
if xcodebuild -version >/dev/null 2>&1; then
  ok "Xcode $(xcodebuild -version | head -1 | awk '{print $2}')  ($(xcode-select -p))"
elif [[ -d /Applications/Xcode.app ]]; then
  miss "已安装 Xcode.app，但当前选中的是 $(xcode-select -p)" \
       "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
else
  miss "Xcode 或命令行工具不可用" "xcode-select --install"
fi

# ---- xcodegen ----
if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen $(xcodegen --version 2>/dev/null | awk '{print $NF}')"
else
  miss "xcodegen 未安装" "brew install xcodegen"
fi

# ---- mysql-client（静态库）----
if brew list --formula mysql-client >/dev/null 2>&1; then
  MYSQL_PREFIX="$(brew --prefix mysql-client)"
  ok "mysql-client ($MYSQL_PREFIX)"
  if [[ -f "$MYSQL_PREFIX/lib/libmysqlclient.a" ]]; then
    ok "libmysqlclient.a 存在"
  else
    miss "找不到 $MYSQL_PREFIX/lib/libmysqlclient.a" "brew reinstall mysql-client"
  fi
  if [[ -f "$MYSQL_PREFIX/include/mysql/mysql.h" ]]; then
    ok "mysql.h 存在"
  else
    miss "找不到 $MYSQL_PREFIX/include/mysql/mysql.h" "brew reinstall mysql-client"
  fi
else
  miss "mysql-client 未安装" "brew install mysql-client"
fi

# ---- 静态链接库 ----
# App 直接把下面这些 .a 链进二进制（决策见 12-build-and-deps.md §3.1），
# 所以它们必须存在；少一个就是链接失败，而不是运行期才发作。
printf "\n== 静态链接库 ==\n"
for spec in "openssl@3:lib/libssl.a" "openssl@3:lib/libcrypto.a" \
            "zstd:lib/libzstd.a" "zlib-ng-compat:lib/libz.a"; do
  formula="${spec%%:*}"; rel="${spec#*:}"
  if brew list --formula "$formula" >/dev/null 2>&1; then
    prefix="$(brew --prefix "$formula")"
    if [[ -f "$prefix/$rel" ]]; then
      ok "$formula  $(basename "$rel")"
    else
      miss "找不到 $prefix/$rel" "brew reinstall $formula"
    fi
  else
    miss "$formula 未安装（缺 $(basename "$rel")）" "brew install $formula"
  fi
done

# ---- 外部认证插件（不是构建依赖，是运行期可选依赖）----
# libmysqlclient 内建 caching_sha2_password / sha256_password；
# mysql_native_password 等只在 lib/plugin/*.so 里，连老服务器时才被 dlopen。
# 详见 docs/tech-designs/13-open-questions.md L41。
if [[ -n "${MYSQL_PREFIX:-}" ]]; then
  if [[ -f "$MYSQL_PREFIX/lib/plugin/mysql_native_password.so" ]]; then
    ok "认证插件 mysql_native_password.so（连老服务器时才用到）"
  else
    note "没有 $MYSQL_PREFIX/lib/plugin/mysql_native_password.so；用 mysql_native_password 账号连服务器会失败"
  fi
fi

printf "\n"
if [[ $fail -ne 0 ]]; then
  printf "${RED}检查未通过，请先修复上面标 ✗ 的项。${RESET}\n\n"
  exit 1
fi

if [[ $warn -ne 0 ]]; then
  printf "${YELLOW}检查通过（有警告）。${RESET}\n\n"
else
  printf "${GREEN}检查通过。${RESET}\n\n"
fi
