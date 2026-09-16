#!/bin/bash
# 一次性生成本机自签名代码签名证书 "Transcriber Dev"。
#
# 为什么需要:macOS 的 TCC 权限(屏幕录制/麦克风)绑定「bundle ID + 签名证书」。
# 用固定证书签名后,designated requirement 稳定,权限跨构建保留。
# 证书无需系统信任(TCC 只比对证书哈希),不弹管理员授权。
set -euo pipefail
cd "$(dirname "$0")"

# 保护本地开发 keychain 的密码(内含自签名证书,证书本身无外部信任价值,
# 但密码不该硬编码进进版本库里的脚本——存在 .env 里,首次运行随机生成,
# .env 已加入 .gitignore。build_app.sh 用同一份 .env,两边天然保持一致,
# 不用像以前那样手动同步两处的硬编码值。
if [[ ! -f .env ]]; then
    echo "TRANSCRIBER_DEV_KEYCHAIN_PASS=$(openssl rand -base64 24)" > .env
    chmod 600 .env
fi
# shellcheck disable=SC1091
source .env
KEYCHAIN_PASS="$TRANSCRIBER_DEV_KEYCHAIN_PASS"
P12_PASS="$TRANSCRIBER_DEV_KEYCHAIN_PASS"  # 只是导出中转用的临时 p12,用同一个密码没问题

if security find-identity -p codesigning 2>/dev/null | grep -q "Transcriber Dev"; then
    echo "✅ 证书 Transcriber Dev 已存在,无需重复创建"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1) openssl 生成带 codeSigning 用途的自签名证书(有效期 10 年)
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/CN=Transcriber Dev" \
    -keyout "$TMP/tdev.key" -out "$TMP/tdev.crt" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
openssl pkcs12 -export -out "$TMP/tdev.p12" -inkey "$TMP/tdev.key" -in "$TMP/tdev.crt" \
    -passout "pass:$P12_PASS" -name "Transcriber Dev"

# 2) 导入专用 keychain(独立密码,避免触碰登录 keychain;build_app.sh 会自动解锁)
KC="$HOME/Library/Keychains/transcriber-dev.keychain-db"
security create-keychain -p "$KEYCHAIN_PASS" transcriber-dev.keychain-db 2>/dev/null || true
security set-keychain-settings transcriber-dev.keychain-db   # 不自动锁定
security unlock-keychain -p "$KEYCHAIN_PASS" transcriber-dev.keychain-db
security import "$TMP/tdev.p12" -k "$KC" -P "$P12_PASS"

# 3) 加入 keychain 搜索列表(保留已有条目,避免覆盖)
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g')
if ! echo "$EXISTING" | grep -q "transcriber-dev.keychain-db"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $EXISTING "$KC"
fi

# 不设置 key partition list，也不以 -T 放行 /usr/bin/codesign：每次签名由 Keychain
# 明确授权，避免任意能执行 codesign 的本机进程静默使用这把私钥。
echo "✅ 证书 Transcriber Dev 已就绪(keychain: transcriber-dev；签名时由 Keychain 授权)"
