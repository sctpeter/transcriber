#!/usr/bin/env python3
"""在 llama-server 所在机器上运行:用网关的 Transcriber(未部署的新代码)直连真实
llama-server,验证默认/覆盖采样都能返回可解析的转写文本,并读 /slots 确认覆盖值被采用。
由 test/test_remote_sampling_live.sh 复制到远端执行,不动已部署的网关进程。

用法: python3 remote_sampling_live_check.py <gateway_dir> <wav> [llama_url]
"""
import asyncio
import json
import sys
import urllib.request

sys.path.insert(0, sys.argv[1])
from qwen3_asr_gateway import Transcriber, parse_sampling  # noqa: E402

WAV = open(sys.argv[2], "rb").read()
URL = sys.argv[3] if len(sys.argv) > 3 else "http://127.0.0.1:8080"
fails = 0


def check(desc, ok, detail=""):
    global fails
    print(f"  {'✅' if ok else '❌'} {desc} {detail}")
    fails += 0 if ok else 1


def slots():
    with urllib.request.urlopen(URL + "/slots", timeout=5) as r:
        return [s["params"] for s in json.loads(r.read())]


async def main():
    t = Transcriber(URL, "qwen3-asr-1.7b-q8_0", 60)

    text = await t.transcribe(WAV, None)
    check("默认采样:返回非空且已去掉 <asr_text> 标记", text and "<asr_text>" not in text, repr(text))

    header = {"sampling": {"samplers": ["top_k", "min_p", "temperature"],
                           "top_k": 17, "top_p": 0.95, "min_p": 0.07, "temperature": 0.0}}
    text2 = await t.transcribe(WAV, parse_sampling(header))
    check("覆盖采样:HTTP 200 且返回非空文本", bool(text2) and "<asr_text>" not in text2, repr(text2))
    applied = [p for p in slots() if p.get("top_k") == 17]
    check("覆盖值被 llama-server 采用(/slots)", len(applied) == 1
          and applied[0]["samplers"] == ["top_k", "min_p", "temperature"]
          and abs(applied[0]["min_p"] - 0.07) < 1e-6 and applied[0]["temperature"] == 0.0,
          json.dumps([{k: p.get(k) for k in ("samplers", "top_k", "min_p", "temperature")} for p in applied]))
    check("温度 0 覆盖与服务器默认输出一致", text == text2)


asyncio.run(main())
print(f"结果: {'全部通过' if fails == 0 else f'{fails} 项失败'}")
sys.exit(1 if fails else 0)
