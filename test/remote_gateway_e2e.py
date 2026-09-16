#!/usr/bin/env python3
"""对已部署的网关做端到端验证:WSS(私有 CA 校验服务端)→ 网关 → llama-server。
发送同一段真实语音两次:不带 sampling(服务器默认)与带 sampling 覆盖;再发一个非法
sampling,确认网关回 error 帧而不是静默忽略。

用法: uv run --with websockets python test/remote_gateway_e2e.py <wss_url> <ca.crt> <wav>
wav 需为 16kHz 单声道 16bit。
"""
import asyncio
import json
import ssl
import sys
import wave

import websockets

url, ca, wav_path = sys.argv[1:4]
with wave.open(wav_path) as w:
    assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2), "需要 16k/mono/16bit"
    pcm = w.readframes(w.getnframes())

SAMPLING = {"samplers": ["top_k", "top_p", "min_p", "temperature"],
            "temperature": 0.0, "top_k": 40, "top_p": 0.95, "min_p": 0.05}
fails = 0


def check(desc, ok, detail=""):
    global fails
    print(f"  {'✅' if ok else '❌'} {desc} {detail}")
    fails += 0 if ok else 1


async def segment(ws, seg_id, sampling):
    header = {"type": "segment", "id": seg_id, "sample_rate": 16000,
              "format": "pcm_s16le", "num_samples": len(pcm) // 2}
    if sampling is not None:
        header["sampling"] = sampling
    await ws.send(json.dumps(header))
    await ws.send(pcm)
    return json.loads(await asyncio.wait_for(ws.recv(), 60))


async def main():
    ctx = ssl.create_default_context(cafile=ca)
    ctx.check_hostname = False  # 服务端证书按 IP 签发;信任只来自私有 CA,和 App 行为一致
    # Python 3.13 默认 VERIFY_X509_STRICT,会以 "Missing Authority Key Identifier" 拒绝
    # make_remote_asr_certs.sh 签出的证书;macOS SecTrust(App 侧)不查这一项。
    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    async with websockets.connect(url, ssl=ctx, max_size=None) as ws:
        r1 = await segment(ws, 1, None)
        check("默认采样返回 result", r1.get("type") == "result" and r1.get("text"), repr(r1))
        r2 = await segment(ws, 2, SAMPLING)
        check("覆盖采样返回 result", r2.get("type") == "result" and r2.get("text"), repr(r2))
        check("温度 0 覆盖与默认输出一致", r1.get("text") == r2.get("text"))
        r3 = await segment(ws, 3, {**SAMPLING, "samplers": ["top_k", "xtc", "temperature"]})
        check("非法采样器被网关拒绝(error 帧)", r3.get("type") == "error", repr(r3))


asyncio.run(main())
print(f"结果: {'全部通过' if fails == 0 else f'{fails} 项失败'}")
sys.exit(1 if fails else 0)
