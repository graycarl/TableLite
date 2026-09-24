#!/usr/bin/env bash
# 生成本机自签名 code signing 证书，导入登录钥匙串，让构建用它签名。
#
# 为什么需要它：ad-hoc 签名（CODE_SIGN_IDENTITY = -）下 App 的「代码身份」就是二进制哈希，
# 改一行代码重新构建就变，Keychain 里「始终允许」记住的授权随之失效 —— 每个密码条目都要
# 重新授权一次。换成自签名证书后代码身份变成 `identifier … and certificate leaf …`，
# 与代码内容无关。决策与接线见 docs/tech-designs/12-build-and-deps.md §3.4。
#
# 幂等：证书已存在就直接退出。证书是**机器本地状态**，不进仓库，也不含任何秘密。
#
# 用法：
#   make signing                        # 建证书 + 重新生成 Configs/Local.xcconfig
#   ./scripts/dev/codesign-identity.sh  # 只建证书
#
# 可用环境变量覆盖：
#   TABLELITE_CODESIGN_IDENTITY_NAME   证书 / 身份名（默认 TableLite Local Dev）
#   TABLELITE_KEYCHAIN                 导入到哪个钥匙串（默认登录钥匙串）
set -euo pipefail

IDENTITY="${TABLELITE_CODESIGN_IDENTITY_NAME:-TableLite Local Dev}"
KEYCHAIN="${TABLELITE_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
die()  { printf "${RED}%s${RESET}\n" "$1" >&2; exit 1; }

printf "\n== 本机签名证书（%s）==\n\n" "$IDENTITY"

trusted() { security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; }

command -v openssl >/dev/null 2>&1 || die "找不到 openssl。修复：brew install openssl@3"
[[ -f "$KEYCHAIN" ]] || die "找不到钥匙串：$KEYCHAIN"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. 生成自签名证书与私钥（已有就跳过 —— 换证书就意味着 Keychain 要重新授权一次）----
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  ok "证书已在钥匙串里，跳过生成"
  security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$WORK/cert.pem" 2>/dev/null || true
else
  cat > "$WORK/cs.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
    -config "$WORK/cs.cnf" >/dev/null 2>&1 || die "生成证书失败"
  ok "已生成自签名证书（有效期 10 年，仅用于本机签名）"

  # OpenSSL 3 默认的 PKCS#12 算法 macOS 的 Security.framework 读不了（报 MAC verification failed），
  # 所以优先用 -legacy；LibreSSL 没有这个开关，失败了退回默认算法。
  P12_PASS="$(openssl rand -hex 32)"
  if openssl pkcs12 -export -legacy -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -passout "pass:$P12_PASS" -name "$IDENTITY" >/dev/null 2>&1; then
    ok "已打包 PKCS#12（-legacy）"
  else
    openssl pkcs12 -export -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -passout "pass:$P12_PASS" -name "$IDENTITY" >/dev/null 2>&1 \
      || die "打包 PKCS#12 失败"
    warn "用了默认 PKCS#12 算法；导入若失败请 brew install openssl@3 后重跑"
  fi

  # -T 让 codesign / security 能用这把钥匙；-A 表示访问密钥时不弹确认框。
  security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null 2>&1 \
    || die "导入钥匙串失败。先 brew install openssl@3 再重跑本脚本。"
  ok "已导入钥匙串：$KEYCHAIN"
fi

# ---- 2. 信任设置 ----
# 自签名证书不标记为受信任的代码签名证书时，find-identity 会报 CSSMERR_TP_NOT_TRUSTED，
# codesign 直接说「no identity found」。这一步写 user 域信任设置，不需要 sudo。
if trusted; then
  ok "已是有效签名身份（信任设置齐备）"
else
  security add-trusted-cert -r trustRoot -p codeSign "$WORK/cert.pem" >/dev/null 2>&1 || true
  if trusted; then
    ok "已标记为受信任的代码签名证书（user 域信任设置）"
    printf "      ${DIM}撤销：钥匙串访问 → 找到「%s」→ 双击 → 信任 → 删除代码签名信任${RESET}\n" "$IDENTITY"
  else
    die "信任设置没生效。手动路径：钥匙串访问 → 找到「$IDENTITY」→ 双击 → 信任 → 「代码签名」选「始终信任」。"
  fi
fi

# ---- 3. 试签一个临时文件，确认这把钥匙真的能用 ----
cp /bin/echo "$WORK/probe"
printf "  试签临时文件…"
set +e
codesign --force --sign "$IDENTITY" "$WORK/probe" >/dev/null 2>&1 &
SIGN_PID=$!
for _ in $(seq 1 30); do
  kill -0 "$SIGN_PID" 2>/dev/null || break
  sleep 1
done
sign_status=0
if kill -0 "$SIGN_PID" 2>/dev/null; then
  kill "$SIGN_PID" 2>/dev/null
  wait "$SIGN_PID" 2>/dev/null
  sign_status=124
  printf "\n"
  warn "30 秒内没签完：多半弹出了钥匙串确认框"
else
  wait "$SIGN_PID"
  sign_status=$?
  if [[ $sign_status -eq 0 ]]; then
    printf "\r  ${GREEN}✓${RESET} 密钥可用，签名正常\n"
  else
    printf "\n"
    warn "试签失败（codesign 退出码 $sign_status）"
  fi
fi
set -e

# 取用密钥不顺时才提这两条；顺的时候不提，避免噪音。
if [[ $sign_status -ne 0 ]]; then
  printf "      ${DIM}若弹出「codesign 想要使用钥匙串中的密钥」，点「始终允许」（只需一次）。${RESET}\n"
  printf "      ${DIM}也可以在终端里补授权：security set-key-partition-list -S apple-tool:,apple:,codesign: -s %s${RESET}\n" "$KEYCHAIN"
fi

printf "\n${GREEN}完成。${RESET}接着：\n"
printf "  1. make run —— 第一次会弹一次 Keychain 授权（旧条目记的是旧的 ad-hoc 身份），点「始终允许」\n"
printf "  2. 之后再怎么改代码重新构建，都不会再弹\n\n"
