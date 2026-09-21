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

# ---- mysql-client ----
if brew list --formula mysql-client >/dev/null 2>&1; then
  MYSQL_PREFIX="$(brew --prefix mysql-client)"
  ok "mysql-client ($MYSQL_PREFIX)"
  if [[ -f "$MYSQL_PREFIX/lib/libmysqlclient.dylib" ]]; then
    ok "libmysqlclient.dylib 存在"
  else
    miss "找不到 $MYSQL_PREFIX/lib/libmysqlclient.dylib" "brew reinstall mysql-client"
  fi
  if [[ -f "$MYSQL_PREFIX/include/mysql/mysql.h" ]]; then
    ok "mysql.h 存在"
  else
    miss "找不到 $MYSQL_PREFIX/include/mysql/mysql.h" "brew reinstall mysql-client"
  fi
else
  miss "mysql-client 未安装" "brew install mysql-client"
fi

# ---- 构建期链接依赖（App 显式 -lssl / -lcrypto / -lzstd，链接器必须能找到）----
for dep in openssl@3 zstd; do
  if brew list --formula "$dep" >/dev/null 2>&1; then
    ok "$dep ($(brew --prefix "$dep"))"
  else
    miss "$dep 未安装" "brew install $dep"
  fi
done

# ---- libmysqlclient 的运行期依赖 ----
# 直接读 dylib 的依赖表，而不是硬编码 formula 名单：Homebrew 换依赖时不会漏检。
# 背景见 docs/tech-designs/12-build-and-deps.md §2、§3.1。
MYSQL_DYLIB="${MYSQL_PREFIX:-}/lib/libmysqlclient.dylib"
if [[ -f "$MYSQL_DYLIB" ]]; then
  if command -v otool >/dev/null 2>&1; then
    while IFS= read -r lib; do
      case "$lib" in
        /opt/homebrew/*)
          formula="$(printf '%s' "$lib" | sed -n 's|^/opt/homebrew/opt/\([^/]*\)/.*|\1|p')"
          if [[ -f "$lib" ]]; then
            ok "运行期依赖 $(basename "$lib")"
          else
            miss "运行期依赖缺失：$lib" "brew reinstall ${formula:-$lib}"
          fi
          ;;
      esac
    done < <(otool -L "$MYSQL_DYLIB" | tail -n +2 | awk '{print $1}')
  else
    note "找不到 otool，跳过 libmysqlclient 的运行期依赖检查"
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
