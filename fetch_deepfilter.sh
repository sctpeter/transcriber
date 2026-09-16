#!/bin/bash
# 构建 DeepFilterNet 的 C API 库(libdeepfilter)到 third_party/deepfilternet/。
#
# 和 fetch_sherpa.sh 不同:upstream 只发布 `deep-filter` CLI 和 LADSPA 插件的预编译产物
# (github.com/Rikorose/DeepFilterNet/releases),没有发布 capi.rs 对应的 C ABI 库,
# 所以这里没有"下载预编译包"这条路,只能本地编译。
# libDF/Cargo.toml 里的 [package.metadata.capi.*] 段是为 `cargo-c` 工具准备的,
# 用它可以一步产出 .dylib/.a + 自动生成的 deep_filter.h + pkg-config 文件。
#
# 依赖:Rust 工具链(https://rustup.rs) + `cargo install cargo-c`。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="v0.5.6"
REPO="https://github.com/Rikorose/DeepFilterNet.git"
OUT="third_party/deepfilternet"

if [[ -f "$OUT/lib/libdeepfilter.dylib" && -f "$OUT/include/deep_filter/deep_filter.h" ]]; then
    echo "已存在 $OUT,跳过构建(删除该目录可强制重新构建)"
    exit 0
fi

if ! command -v cargo >/dev/null; then
    echo "❌ 未找到 cargo。请先安装 Rust 工具链: https://rustup.rs" >&2
    exit 1
fi
if ! cargo capi --version >/dev/null 2>&1; then
    echo "未找到 cargo-c,正在安装(cargo install cargo-c)..."
    cargo install cargo-c
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "克隆 DeepFilterNet $VERSION ..."
git clone --depth 1 --branch "$VERSION" "$REPO" "$WORK/DeepFilterNet"

echo "编译 libdeepfilter(features=capi,内含默认 DFN3 模型,产物较大属正常)..."
(
    cd "$WORK/DeepFilterNet/libDF"
    # v0.5.6 锁定的 time 0.3.28 在较新 rustc 上有个已知类型推断问题(E0282),
    # 上游还没发新 tag 修,这里主动升级这一个传递依赖绕过去,不影响 libdf 本身代码。
    cargo update -p time || true
    # cbindgen.toml(language=C,否则默认生成 C++ 风格头文件,含 <cstdint>/extern "C"
    # 不加 #ifdef __cplusplus 保护,Swift systemLibrary 按纯 C 解析会直接报头文件找不到)
    # 放在仓库根目录,但 cargo-c 只在被编译的 crate 目录(libDF/)里找,必须拷一份进来。
    cp ../cbindgen.toml .
    # cargo-c 对"没有源码变化"的重复构建会跳过头文件重新生成,直接吃缓存,
    # 干净目录保证这次一定会用上面这份 cbindgen.toml 重新生成头文件。
    cargo capi install --release --features capi --no-default-features \
        --destdir "$WORK/install" --prefix /
)

mkdir -p "$OUT"
rm -rf "$OUT"/*
cp -R "$WORK/install/lib" "$OUT/lib"
cp -R "$WORK/install/include" "$OUT/include"

# cargo-c 用 --prefix / 生成的 dylib,install name(LC_ID_DYLIB)被写死成绝对路径
# /lib/libdeepfilter.0.5.dylib——这台机器能跑,换个路径/换台机器就找不到库了。
# 改成 @rpath 相对路径,和 sherpa-onnx 预编译库的做法一致(Package.swift 已经在
# 链接参数里加了 -rpath third_party/deepfilternet/lib)。install_name_tool 会让
# 签名失效,顺手用 ad-hoc 身份重签一下。
real_dylib="$(find "$OUT/lib" -name 'libdeepfilter.*.dylib' ! -type l | head -1)"
if [[ -n "$real_dylib" ]]; then
    install_name_tool -id "@rpath/libdeepfilter.dylib" "$real_dylib"
    codesign --sign - --force "$real_dylib"
fi

echo "✅ third_party/deepfilternet/{lib,include} 已生成"
ls -la "$OUT/lib" "$OUT/include/deep_filter"
