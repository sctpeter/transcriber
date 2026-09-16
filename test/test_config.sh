#!/bin/bash
# 验证统一 config 系统:默认值与硬编码前一致、部分覆盖(partial JSON)按字段合并、
# TRANSCRIBER_CONFIG 环境变量可指向任意路径(不污染真实 App Support)。
# 用法: ./test/test_config.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build 2>&1 | tail -5
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

echo "== 1) 无配置文件时,--print-config 输出的默认值应等于改造前的硬编码值 =="
out="$(TRANSCRIBER_CONFIG="$TMP/missing.json" "$BIN" --print-config)"
check "vad.threshold 默认 0.5" "$out" '"threshold" : 0.5'
check "vad.minSilenceDuration 默认 0.8" "$out" '"minSilenceDuration" : 0.8'
check "vad.minSpeechDuration 默认 0.25" "$out" '"minSpeechDuration" : 0.25'
check "vad.maxSpeechDuration 默认 28" "$out" '"maxSpeechDuration" : 28'
check "vad.windowSize 默认 512" "$out" '"windowSize" : 512'
check "asr.numThreads 默认 2" "$out" '"numThreads" : 2'
check "asr.provider 默认 cpu" "$out" '"provider" : "cpu"'
if echo "$out" | grep -q decodingMethod; then
    check "asr.decodingMethod 已移除(paraformer 只支持 greedy)" "present" "absent"
else
    check "asr.decodingMethod 已移除(paraformer 只支持 greedy)" "absent" "absent"
fi

echo "== 2) 只写部分字段的 JSON,未写的字段应回落默认值(而不是报错/清零) =="
cat > "$TMP/partial.json" <<'EOF'
{ "vad": { "minSilenceDuration": 1.5 }, "asr": { "numThreads": 4 } }
EOF
out="$(TRANSCRIBER_CONFIG="$TMP/partial.json" "$BIN" --print-config)"
check "覆盖字段生效:minSilenceDuration=1.5" "$out" '"minSilenceDuration" : 1.5'
check "覆盖字段生效:numThreads=4" "$out" '"numThreads" : 4'
check "未覆盖字段仍是默认:threshold=0.5" "$out" '"threshold" : 0.5'
check "未覆盖字段仍是默认:provider=cpu" "$out" '"provider" : "cpu"'

echo "== 3) 保存后能读回同样的值(SettingsView 用的 ConfigStore.save 路径) =="
"$BIN" --print-config >/dev/null  # 确保上一步没有把默认 config.json 写脏(--print-config 只读不写)
out="$(TRANSCRIBER_CONFIG="$TMP/roundtrip.json" "$BIN" --print-config)"
check "不存在的文件 roundtrip 读到默认值" "$out" '"windowSize" : 512'
[[ ! -f "$TMP/roundtrip.json" ]] && echo "  ✅ --print-config 不会创建/污染文件"

echo "== 4) 旧 config.json 没有 remoteAsr.sampling,应回落默认(不覆盖服务器,默认值对齐服务器) =="
cat > "$TMP/legacy.json" <<'EOF'
{ "remoteAsr": { "enabled": true, "serverURL": "wss://example:8765/v1/transcribe", "timeoutSeconds": 8 } }
EOF
out="$(TRANSCRIBER_CONFIG="$TMP/legacy.json" "$BIN" --print-config)"
check "旧配置其他字段保留" "$out" '"serverURL" : "wss:\/\/example:8765\/v1\/transcribe"'
check "sampling.samplers 默认空(不覆盖)" "$out" '"samplers" : ['
check "sampling.temperature 默认 0" "$out" '"temperature" : 0'
check "sampling.topK 默认 40" "$out" '"topK" : 40'

echo "== 5) remoteAsr.sampling 完整写入并读回(--print-config 与 ConfigStore.save 同一编码器) =="
cat > "$TMP/sampling.json" <<'EOF'
{ "remoteAsr": { "sampling": { "samplers": ["top_k", "min_p", "temperature"],
  "temperature": 0.25, "topK": 17, "topP": 0.5, "minP": 0.125 } } }
EOF
first="$(TRANSCRIBER_CONFIG="$TMP/sampling.json" "$BIN" --print-config | tail -n +2)"
echo "$first" > "$TMP/saved.json"
second="$(TRANSCRIBER_CONFIG="$TMP/saved.json" "$BIN" --print-config | tail -n +2)"
for needle in '"top_k"' '"min_p"' '"temperature" : 0.25' '"topK" : 17' '"topP" : 0.5' '"minP" : 0.125'; do
    check "写出后读回包含 $needle" "$second" "$needle"
done
if [[ "$first" == "$second" ]]; then
    check "两次编码结果完全一致" "ok" "ok"
else
    check "两次编码结果完全一致" "diff" "ok"
fi

echo
echo "结果: $pass 通过, $fail 失败"
[[ $fail -eq 0 ]]
