#!/usr/bin/env python3
"""test_remote_asr.sh 专用的假 Qwen3-ASR 网关:不跑任何模型,收到一个 segment 就回
固定文本,用来验证 Swift 客户端(RemoteAsrRefiner)的 mTLS 握手 + 协议编解码 +
顺序保证,不依赖真实 llama-server/Qwen3-ASR 模型。

协议和 server/qwen3_asr_gateway.py 完全一致(见 docs/0003),这里只是把
"调用 llama-server"换成"返回写死的文本"。
"""
import argparse
import asyncio
import json
import sys
from pathlib import Path

import websockets

# 复用 server/qwen3_asr_gateway.py 里的 build_ssl_context,而不是在这里再抄一份
# SSL 配置逻辑——两边分开写迟早会跑偏(比如只改了一边的 --ca 可选逻辑)。
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))
from qwen3_asr_gateway import build_ssl_context  # noqa: E402

FIXED_TEXT = "mock-transcript-ok"


async def handle(ws):
    pending_header = None
    try:
        async for message in ws:
            if isinstance(message, str):
                pending_header = json.loads(message)
                continue
            if pending_header is None:
                continue
            header, pending_header = pending_header, None
            await ws.send(json.dumps({"type": "result", "id": header["id"], "text": FIXED_TEXT}))
    except websockets.exceptions.ConnectionClosed:
        pass


async def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--ca", default=None, help="不传 = 不校验客户端证书,和真实网关行为一致")
    args = p.parse_args()

    ctx = build_ssl_context(args.cert, args.key, args.ca)

    async with websockets.serve(handle, "127.0.0.1", args.port, ssl=ctx):
        print("LISTENING", flush=True)  # 测试脚本轮询这一行判断服务已就绪
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
