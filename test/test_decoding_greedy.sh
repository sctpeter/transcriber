#!/bin/bash
# 回归:旧 config.json 里残留 asr.decodingMethod=modified_beam_search 时,不能再让
# sherpa-onnx 在 C++ 里 exit(-1) 闪退(paraformer 只支持 greedy_search,见 docs/0007)。
# 用 macOS `say` 合成一段英文语音跑无头 --selftest,确认能走完识别。
# 用法: ./test/test_decoding_greedy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build 2>&1 | tail -3
BIN=".build/debug/Transcriber"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say -o "$TMP/hello.wav" --data-format=LEI16@16000 "hello this is a test"
cat > "$TMP/legacy.json" <<JSON
{ "asr": { "decodingMethod": "modified_beam_search" },
  "remoteAsr": { "enabled": false },
  "paths": { "recordingsRoot": "$TMP" } }
JSON

set +e
out="$(TRANSCRIBER_CONFIG="$TMP/legacy.json" "$BIN" --selftest "$TMP/hello.wav" 2>&1)"
code=$?
set -e

pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }

echo "== 旧配置 decodingMethod=modified_beam_search =="
[[ $code -eq 0 ]] && ok "selftest 正常退出(exit 0)" || bad "selftest 退出码 $code"
echo "$out" | grep -q "Only greedy_search is supported" \
    && bad "sherpa-onnx 仍收到了 modified_beam_search" || ok "没有把 modified_beam_search 传给 sherpa-onnx"
echo "$out" | grep -qi "hello this is a test" && ok "识别结果正确" || bad "未得到识别结果"

echo "== --print-config 不再包含 decodingMethod =="
TRANSCRIBER_CONFIG="$TMP/legacy.json" "$BIN" --print-config | grep -q decodingMethod \
    && bad "仍输出 decodingMethod" || ok "已移除"

echo
echo "结果: $pass 通过, $fail 失败"
[[ $fail -eq 0 ]]
