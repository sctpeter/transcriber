#!/bin/bash
# 验证降噪预处理链路:config 默认值/部分覆盖、HighPassFilter 实际频响、
# DeepFilterNet3 模型缺失时的优雅降级(不阻断录音)。
#
# 不依赖真实 DeepFilterNet3 模型文件/libdeepfilter 编译产物——那部分需要先跑
# ./fetch_deepfilter.sh(需要 Rust 工具链),这里只测试链路本身的正确性与容错。
# 用法: ./test/test_denoise.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build 2>&1 | tail -20
BIN=".build/debug/Transcriber"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  ✅ $desc"
        pass=$((pass + 1))
    else
        echo "  ❌ $desc (未找到: $needle)"
        fail=$((fail + 1))
    fi
}
check_exit() {
    # set -e 下不能直接用 `cmd; check_exit $?`(cmd 失败会先触发 errexit),
    # 调用方必须写成 `if cmd; then check_exit desc 0; else check_exit desc 1; fi`
    local desc="$1" code="$2"
    if [[ "$code" -eq 0 ]]; then
        echo "  ✅ $desc"
        pass=$((pass + 1))
    else
        echo "  ❌ $desc (退出码 $code)"
        fail=$((fail + 1))
    fi
}

echo "== 1) config 默认值:降噪/远程 ASR 默认全关,不改变现有行为 =="
out="$(TRANSCRIBER_CONFIG="$TMP/missing.json" "$BIN" --print-config)"
check "highPass 默认关闭" "$out" '"enabled" : false'
check "highPass cutoffHz 默认 80" "$out" '"cutoffHz" : 80'
check "deepFilterNet attenLimitDb 默认 30" "$out" '"attenLimitDb" : 30'
check "remoteAsr 默认 timeoutSeconds 8" "$out" '"timeoutSeconds" : 8'

echo "== 2) 部分覆盖 JSON:只写 denoise.highPass,其余字段落默认值 =="
cat > "$TMP/partial.json" <<'EOF'
{ "denoise": { "highPass": { "enabled": true, "cutoffHz": 100 } } }
EOF
out="$(TRANSCRIBER_CONFIG="$TMP/partial.json" "$BIN" --print-config)"
check "highPass.enabled 覆盖生效" "$out" '"enabled" : true'
check "highPass.cutoffHz 覆盖生效" "$out" '"cutoffHz" : 100'
check "deepFilterNet 仍是默认关闭" "$out" '"attenLimitDb" : 30'

echo "== 3) HighPassFilter 实际频响(合成 30Hz/1000Hz 纯音,不依赖模型文件) =="
if "$BIN" --selftest-highpass; then
    check_exit "30Hz 明显衰减、1000Hz 基本无损通过" 0
else
    check_exit "30Hz 明显衰减、1000Hz 基本无损通过" 1
fi

echo "== 4) DeepFilterNet3 模型路径指向不存在的文件时优雅降级(不崩溃、退化为仅高通) =="
if "$BIN" --selftest-denoise-guard; then
    check_exit "模型缺失时 AudioPreprocessor 不崩溃、输出帧数不变" 0
else
    check_exit "模型缺失时 AudioPreprocessor 不崩溃、输出帧数不变" 1
fi

echo
echo "结果: $pass 通过, $fail 失败"
[[ $fail -eq 0 ]]
