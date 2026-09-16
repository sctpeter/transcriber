#!/bin/bash
# 真实远端验证:把本地(未部署)的网关代码复制到 wangtian03 临时目录,用 conda 环境的
# python 直连 llama-server 跑默认/覆盖采样。不替换、不重启已部署的网关。
# 用法: ./test/test_remote_sampling_live.sh [ssh_host] [远端 wav]
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:-wangtian03}"
WAV="${2:-/tmp/test.wav}"
PY=/home/peter/miniconda3/envs/transcriber-asr/bin/python3

REMOTE_DIR="$(ssh "$HOST" mktemp -d)"
trap 'ssh "$HOST" rm -rf "$REMOTE_DIR"' EXIT
scp -q server/qwen3_asr_gateway.py test/remote_sampling_live_check.py "$HOST:$REMOTE_DIR/"
ssh "$HOST" "$PY $REMOTE_DIR/remote_sampling_live_check.py $REMOTE_DIR $WAV"
