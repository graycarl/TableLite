#!/usr/bin/env bash
# 构建 Release 并打包成可分发的 zip。
#
# 全静态链接（T1 重定案，见 docs/tech-designs/12-build-and-deps.md §3.1）：产物不引用任何
# Homebrew dylib，所以打包前反过来断言「一个都没有」，防止链接配置悄悄退回动态链接。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
APP="$BUILD_DIR/Build/Products/Release/TableLite.app"

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'

echo "==> xcodebuild (Release)"
xcodebuild \
  -project "$ROOT/TableLite.xcodeproj" \
  -scheme TableLite \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -quiet \
  build

if [[ ! -d "$APP" ]]; then
  printf "${RED}找不到 %s${RESET}\n" "$APP" >&2
  exit 1
fi

# Release 构建没有 Xcode 27 的 debug dylib，主二进制就是全部依赖的持有者
BINARY="$APP/Contents/MacOS/TableLite"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "==> 检查运行期依赖（Release 二进制）"
# T1 重定案（2026-09-24，见 12-build-and-deps.md §3.1）：全静态链接，产物不应再引用任何
# Homebrew 路径。这里反过来断言「一个都没有」——残留就说明链接配置被改回了动态。
homebrew_refs="$(otool -L "$BINARY" | tail -n +2 | awk '{print $1}' | grep '^/opt/homebrew/' || true)"
if [[ -n "$homebrew_refs" ]]; then
  printf "  ${RED}✗${RESET} 产物仍引用 Homebrew 动态库：\n" >&2
  printf '%s\n' "$homebrew_refs" | sed 's/^/      /' >&2
  printf "      ${RED}链接配置被改回了动态链接？检查 project.yml 的 OTHER_LDFLAGS。${RESET}\n" >&2
  exit 1
fi
system_libs="$(otool -L "$BINARY" | tail -n +2 | awk '{print $1}' | grep -vc '^/opt/homebrew/')"
printf "  ${GREEN}✓${RESET} 无 Homebrew 动态库引用（其余 %s 项均为系统库）\n" "$system_libs"

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/TableLite-$VERSION.zip"
rm -f "$ZIP"

echo "==> 打包"
# --keepParent 让解压后直接得到 TableLite.app，而不是散落的目录内容
ditto -c -k --keepParent "$APP" "$ZIP"

printf "\n${GREEN}%s${RESET}\n" "$ZIP"
ls -lh "$ZIP" | awk '{print "  大小 " $5}'
printf "  注意：产物不依赖目标机器的 Homebrew，换机解开就能用。\n"
printf "        唯一例外：用 mysql_native_password 账号连老服务器时需要\n"
printf "        mysql-client 的认证插件（见 13-open-questions.md L41）。\n"
