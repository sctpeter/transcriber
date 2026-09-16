#!/bin/bash
# 验证远程 Qwen3-ASR 通道的网络层:证书体系自签自验、mTLS 握手+协议编解码、
# 证书不匹配时优雅拒绝并回退本地精修。不需要真实部署 llama-server/下载 Qwen3-ASR
# 模型——用 test/remote_asr_mock_server.py 假服务端替代真实推理(见 docs/0003)。
# 用法: ./test/test_remote_asr.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build 2>&1 | tail -20
BIN=".build/debug/Transcriber"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

pass=0
fail=0
check() {
    local desc="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        echo "  ✅ $desc"
        pass=$((pass + 1))
    else
        echo "  ❌ $desc (期望 \"$want\",实际 \"$got\")"
        fail=$((fail + 1))
    fi
}

PORT=18765
CERT_ROOT="$TMP/certs_ok"
mkdir -p "$CERT_ROOT"
cp certs/make_remote_asr_certs.sh "$CERT_ROOT/"
(cd "$CERT_ROOT" && ./make_remote_asr_certs.sh init >/dev/null
 ./make_remote_asr_certs.sh server 127.0.0.1 >/dev/null
 P12_PASS=testpass ./make_remote_asr_certs.sh client test-client >/dev/null)

echo "== 1) 证书链自签自验 =="
if openssl verify -CAfile "$CERT_ROOT/ca/ca.crt" "$CERT_ROOT/server/server.crt" >/dev/null 2>&1; then
    check "server.crt 能被 ca.crt 验证通过" "ok" "ok"
else
    check "server.crt 能被 ca.crt 验证通过" "fail" "ok"
fi

echo "== 2) 起 mock 网关,合法证书应该收到远程结果 =="
python3 test/remote_asr_mock_server.py --port "$PORT" \
    --cert "$CERT_ROOT/server/server.crt" --key "$CERT_ROOT/server/server.key" \
    --ca "$CERT_ROOT/ca/ca.crt" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    grep -q LISTENING "$TMP/server.log" 2>/dev/null && break
    sleep 0.1
done
if ! grep -q LISTENING "$TMP/server.log" 2>/dev/null; then
    echo "  ❌ mock 网关没能在 5s 内启动,日志:"
    cat "$TMP/server.log"
    exit 1
fi

got="$("$BIN" --selftest-remote-asr "wss://127.0.0.1:$PORT/v1/transcribe" \
    "$CERT_ROOT/client/client.p12" "testpass" "$CERT_ROOT/ca/ca.crt" 5 | tail -1)"
check "合法证书连接,收到 mock 服务端返回的文本" "$got" "mock-transcript-ok"

kill "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo "== 3) 客户端证书是另一套 CA 签的,握手应被拒绝、回退本地精修 =="
CERT_BAD="$TMP/certs_bad"
mkdir -p "$CERT_BAD"
cp certs/make_remote_asr_certs.sh "$CERT_BAD/"
(cd "$CERT_BAD" && ./make_remote_asr_certs.sh init >/dev/null
 P12_PASS=testpass ./make_remote_asr_certs.sh client test-client-bad >/dev/null)

python3 test/remote_asr_mock_server.py --port "$PORT" \
    --cert "$CERT_ROOT/server/server.crt" --key "$CERT_ROOT/server/server.key" \
    --ca "$CERT_ROOT/ca/ca.crt" > "$TMP/server2.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
    grep -q LISTENING "$TMP/server2.log" 2>/dev/null && break
    sleep 0.1
done

got="$("$BIN" --selftest-remote-asr "wss://127.0.0.1:$PORT/v1/transcribe" \
    "$CERT_BAD/client/client.p12" "testpass" "$CERT_ROOT/ca/ca.crt" 3 | tail -1)"
check "证书不匹配,回退到本地精修而不是卡死/崩溃" "$got" "LOCAL_FALLBACK_TEXT"

kill "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo "== 4) 默认部署形态:服务端不传 --ca(不校验客户端证书),客户端也不出示证书,仍应正常连接 =="
python3 test/remote_asr_mock_server.py --port "$PORT" \
    --cert "$CERT_ROOT/server/server.crt" --key "$CERT_ROOT/server/server.key" \
    > "$TMP/server3.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
    grep -q LISTENING "$TMP/server3.log" 2>/dev/null && break
    sleep 0.1
done

got="$("$BIN" --selftest-remote-asr "wss://127.0.0.1:$PORT/v1/transcribe" \
    "" "" "$CERT_ROOT/ca/ca.crt" 5 | tail -1)"
check "不带客户端证书也能连接(单向 TLS,仍校验服务端身份)" "$got" "mock-transcript-ok"

kill "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo
echo "结果: $pass 通过, $fail 失败"
[[ $fail -eq 0 ]]
