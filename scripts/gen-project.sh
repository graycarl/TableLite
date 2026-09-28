#!/usr/bin/env bash
# 生成 Xcode 工程。输入没变就整段跳过。
#
# 跳过的是三项固定开销（实测合计 ~7.1s，其中 xcodegen 本身只占 0.05s）：
#   check-deps.sh          2.1s（全是 brew 调用）
#   gen-local-xcconfig.sh  4.9s（4 次 brew --prefix + security find-identity + 5 次 otool）
#   xcodegen generate      0.05s
#
# 指纹 = project.yml 的内容 + Sources/ 与 Tests/ 下的文件清单。
# 改已有文件的内容不需要重新生成工程；改 project.yml 或增删文件会命中指纹变化自动重跑，
# 所以不再依赖人记住「改了 project.yml 要 make gen」。
#
# 代价：brew upgrade 之后不会再自动重算 Local.xcconfig 的路径与部署目标，要手动 make deps。
# 决策与理由见 docs/tech-designs/12-build-and-deps.md §4.2、13-open-questions.md S43。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/TableLite.xcodeproj"
XCCONFIG="$ROOT/Configs/Local.xcconfig"
STATE="$ROOT/.build/gen-fingerprint"

fingerprint() {
  {
    cat "$ROOT/project.yml"
    # 只取路径清单，不取内容：内容变化不影响工程结构。
    find "${ROOT}/Sources" "${ROOT}/Tests" -type f -print \
      | sed "s|^${ROOT}/||" \
      | sort
  } | shasum -a 256 | awk '{print $1}'
}

CURRENT="$(fingerprint)"

if [[ -d "$PROJECT" && -f "$XCCONFIG" && -f "$STATE" && "$(cat "$STATE")" == "$CURRENT" ]]; then
  echo "==> 工程输入未变，跳过依赖检查与 xcodegen"
  exit 0
fi

"${ROOT}/scripts/check-deps.sh"
"${ROOT}/scripts/gen-local-xcconfig.sh"
echo "==> xcodegen generate"
( cd "$ROOT" && xcodegen generate )

mkdir -p "$(dirname "$STATE")"
printf '%s\n' "$CURRENT" > "$STATE"
