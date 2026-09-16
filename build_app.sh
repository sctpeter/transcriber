#!/bin/bash
# 构建 Transcriber.app:swift build → 组装 bundle → 签名(固定 bundle ID;
# 优先自签名证书 "Transcriber Dev",证书不存在时回退 ad-hoc)
# 用法: ./build_app.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Transcriber.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/release/Transcriber "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# sherpa-onnx + DeepFilterNet 动态库进 bundle(可执行文件 rpath 已含
# @executable_path/../Frameworks)。-L 解引用 libdeepfilter.dylib 符号链接,
# 因为运行时按 @rpath/libdeepfilter.dylib 这个确切文件名找,bundle 里放符号链接
# 目标不一致的话文件名对不上。
cp third_party/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib \
   third_party/sherpa-onnx/lib/libonnxruntime.1.24.4.dylib \
   "$APP/Contents/Frameworks/"
cp -L third_party/deepfilternet/lib/libdeepfilter.dylib \
   "$APP/Contents/Frameworks/libdeepfilter.dylib"

# 签名身份:优先固定的自签名证书 "Transcriber Dev"(TCC 权限跨构建保留);
# 证书不存在时退回 ad-hoc(每次构建 cdhash 变,屏幕录制需重新授权)。
IDENTITY="-"
# 注:自签名证书未标记系统信任时 -v 不会列出,但 codesign 可正常使用,故不带 -v 检测
if security find-identity -p codesigning 2>/dev/null | grep -q "Transcriber Dev"; then
    IDENTITY="Transcriber Dev"
    # 专用 keychain 重启后会锁定,签名前解锁。密码存在 .env 里(不进版本库,
    # make_signing_cert.sh 首次运行生成),和该脚本共用同一份,不再是硬编码
    # 明文——如果 .env 还不存在(比如先跑了这个脚本没跑 make_signing_cert.sh),
    # 直接跳过解锁,codesign 失败时的报错会提示去跑 make_signing_cert.sh。
    if [[ -f .env ]]; then
        # shellcheck disable=SC1091
        source .env
        security unlock-keychain -p "$TRANSCRIBER_DEV_KEYCHAIN_PASS" \
            ~/Library/Keychains/transcriber-dev.keychain-db 2>/dev/null || true
    fi
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign "$IDENTITY" --identifier local.transcriber "$APP"
echo "签名身份: $IDENTITY"

echo "✅ 构建完成: $PWD/$APP"

if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
