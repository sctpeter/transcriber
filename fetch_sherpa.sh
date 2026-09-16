#!/bin/bash
# 下载 sherpa-onnx 预编译库到 third_party/
set -euo pipefail
cd "$(dirname "$0")/third_party" 2>/dev/null || { mkdir -p "$(dirname "$0")/third_party"; cd "$(dirname "$0")/third_party"; }

VERSION="1.13.3"
NAME="sherpa-onnx-v${VERSION}-osx-arm64-shared-no-tts"

if [[ -d "$NAME" ]]; then
    echo "已存在 $NAME,跳过下载"
else
    curl -L -o "$NAME.tar.bz2" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${NAME}.tar.bz2"
    tar xjf "$NAME.tar.bz2"
    rm "$NAME.tar.bz2"
fi

ln -sfn "$NAME" sherpa-onnx
echo "✅ third_party/sherpa-onnx → $NAME"
