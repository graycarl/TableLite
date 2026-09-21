#!/usr/bin/env bash
# 构建 Release 并打包成可分发的 zip。
#
# 决策见 docs/tech-designs/12-build-and-deps.md §4.1：
# 产物**不内嵌** Homebrew 的 dylib（T1 已定案），所以打包前必须确认它们都还在 ——
# 否则会得到一个看起来正常、换台机器就跑不起来的 zip。
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
missing=0
while IFS= read -r lib; do
  case "$lib" in
    /opt/homebrew/*)
      if [[ -f "$lib" ]]; then
        printf "  ${GREEN}✓${RESET} %s\n" "$(basename "$lib")"
      else
        printf "  ${RED}✗${RESET} 缺失：%s\n" "$lib" >&2
        missing=1
      fi
      ;;
  esac
done < <(otool -L "$BINARY" | tail -n +2 | awk '{print $1}')

if [[ $missing -ne 0 ]]; then
  printf "${RED}依赖缺失，产物换机跑不起来。先 brew reinstall 对应的 formula。${RESET}\n" >&2
  exit 1
fi

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/TableLite-$VERSION.zip"
rm -f "$ZIP"

echo "==> 打包"
# --keepParent 让解压后直接得到 TableLite.app，而不是散落的目录内容
ditto -c -k --keepParent "$APP" "$ZIP"

printf "\n${GREEN}%s${RESET}\n" "$ZIP"
ls -lh "$ZIP" | awk '{print "  大小 " $5}'
printf "  注意：产物仍依赖目标机器的 Homebrew（mysql-client / openssl@3 / zstd），\n"
printf "        换机前先 brew install mysql-client。见 12-build-and-deps.md §4.1。\n"
