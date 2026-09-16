#!/usr/bin/env python3
"""Qwen3-ASR-1.7B Q8 远程转写网关。

职责划分(见 docs/0003_remote_qwen3_asr_protocol.md):
  - 这个进程只负责"内网可达的 TLS(默认单向,--ca 可选升级成双向 mTLS)+
    WebSocket 面",不自己跑模型推理。
  - 真正的 ASR 推理交给 llama.cpp 的 llama-server(它本来就有 OpenAI 兼容的
    /v1/audio/transcriptions 端点,Qwen3-ASR-1.7B-GGUF 官方就是这么跑的),
    llama-server 只监听 127.0.0.1,不直接暴露给客户端——这样 mTLS 终止和模型服务
    分开,换模型/升级 llama.cpp 不用碰这层网关代码。

部署:
  1) 参照 server/README.md 起一个 llama-server(Qwen3-ASR-1.7B-GGUF, Q8_0)。
  2) 用 certs/make_remote_asr_certs.sh 签发这台机器的 server 证书。
  3) python3 qwen3_asr_gateway.py --cert ... --key ... --ca ...

协议:每个 WebSocket 连接上,客户端逐段发送
  1. 一条 TEXT 帧: {"type":"segment","id":N,"sample_rate":16000,"format":"pcm_s16le","num_samples":M}
  2. 紧跟一条 BINARY 帧:M 个 int16 little-endian 采样
服务端处理完回一条 TEXT 帧:
  {"type":"result","id":N,"text":"..."} 或 {"type":"error","id":N,"message":"..."}
"""
from __future__ import annotations

import argparse
import asyncio
import io
import json
import logging
import ssl
import wave

import websockets

log = logging.getLogger("qwen3_asr_gateway")


def pcm16_to_wav_bytes(pcm: bytes, sample_rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)  # int16
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return buf.getvalue()


def extract_asr_text(raw: str) -> str:
    """llama-server 对 Qwen3-ASR-1.7B-GGUF 的 /v1/audio/transcriptions 响应里,
    `text` 字段不是纯转写文本,而是 `language <lang><asr_text><转写内容>` 这种带标记
    的原始模型输出(2026-09-16 用 llama.cpp b10991 实测确认,不是文档行为,后续升级
    llama.cpp 需要重新验证这个格式)。这里只取 `<asr_text>` 之后的部分。
    """
    marker = "<asr_text>"
    idx = raw.find(marker)
    if idx == -1:
        return raw.strip()
    return raw[idx + len(marker) :].strip()


class Transcriber:
    """薄封装:把一段 WAV 转发给 llama-server 的 OpenAI 兼容转写端点。

    aiohttp 在方法内部才 import(而不是模块顶层):这样 build_ssl_context 这个
    纯 SSL 配置工具函数可以被 test/remote_asr_mock_server.py 复用,而不用逼着
    只想测证书握手的场景也装一份 aiohttp。
    """

    def __init__(self, llama_server_url: str, model_name: str, timeout: float):
        import aiohttp

        self.url = llama_server_url.rstrip("/") + "/v1/audio/transcriptions"
        self.model_name = model_name
        self.timeout = aiohttp.ClientTimeout(total=timeout)

    async def transcribe(self, wav_bytes: bytes) -> str:
        import aiohttp

        form = aiohttp.FormData()
        form.add_field("model", self.model_name)
        form.add_field(
            "file", wav_bytes, filename="segment.wav", content_type="audio/wav"
        )
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            async with session.post(self.url, data=form) as resp:
                resp.raise_for_status()
                data = await resp.json()
        # data["text"] 不是纯转写文本,见 extract_asr_text 的注释
        return extract_asr_text(data.get("text", ""))


async def handle_connection(ws, transcriber: Transcriber):
    peer = ws.remote_address
    log.info("客户端连接: %s", peer)
    pending_header = None
    try:
        async for message in ws:
            if isinstance(message, str):
                try:
                    header = json.loads(message)
                except json.JSONDecodeError:
                    log.warning("忽略无法解析的控制帧: %r", message[:200])
                    continue
                if header.get("type") != "segment":
                    continue
                pending_header = header
                continue

            # 二进制帧:必须紧跟在一条 segment 控制帧之后
            if pending_header is None:
                log.warning("收到未预期的二进制帧(前面没有 segment 控制帧),丢弃")
                continue
            header, pending_header = pending_header, None
            seg_id = header.get("id")
            sample_rate = int(header.get("sample_rate", 16000))
            expected = int(header.get("num_samples", 0)) * 2
            if expected and len(message) != expected:
                log.warning(
                    "segment %s 字节数不符:期望 %d,实际 %d", seg_id, expected, len(message)
                )
            try:
                wav_bytes = pcm16_to_wav_bytes(message, sample_rate)
                text = await transcriber.transcribe(wav_bytes)
                await ws.send(json.dumps({"type": "result", "id": seg_id, "text": text}))
            except Exception as e:  # noqa: BLE001 - 单个 segment 出错不能拖垮整条连接
                log.exception("segment %s 转写失败", seg_id)
                await ws.send(
                    json.dumps({"type": "error", "id": seg_id, "message": str(e)})
                )
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        log.info("客户端断开: %s", peer)


def build_ssl_context(cert: str, key: str, ca: str | None) -> ssl.SSLContext:
    """ca 是否传入决定要不要验客户端证书(双向 mTLS),这是一个部署时的配置开关,
    不是写死的行为。

    2026-09-16 定的默认策略:私有局域网、人数少,不需要认证"是谁在连",只要
    保证传输加密 + 客户端能验证服务端身份就够了,所以默认部署(见
    server/README.md、ecosystem.config.js)不传 --ca,`verify_mode` 就是
    `CERT_NONE`——这也是老实反映现状:实测过 TLS 1.3 下 Python ssl 模块的
    客户端证书校验默认走"握手后认证"(post-handshake auth),`CERT_REQUIRED`
    在初始握手阶段并不会真的要求客户端证书,`websockets` 库也没有现成钩子接
    `verify_client_post_handshake()`,勉强接进去在没有先例的情况下维护成本
    很高,所以没有做成"看起来强制、实际上没生效"的假 mTLS。

    以后要重新收紧成双向认证,起服务时加上 --ca 就行,不用改这份代码。
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=cert, keyfile=key)
    if ca:
        ctx.load_verify_locations(cafile=ca)
        ctx.verify_mode = ssl.CERT_REQUIRED
    else:
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--cert", required=True, help="服务端证书 (certs/server/server.crt)")
    parser.add_argument("--key", required=True, help="服务端私钥 (certs/server/server.key)")
    parser.add_argument(
        "--ca",
        default=None,
        help="私有 CA 证书 (certs/ca/ca.crt);传了才会校验客户端证书(双向 mTLS)。"
        "不传 = 只做单向 TLS,不认证客户端是谁(默认,见 build_ssl_context 的说明)",
    )
    parser.add_argument(
        "--llama-server-url", default="http://127.0.0.1:8080", help="本机 llama-server 地址"
    )
    parser.add_argument(
        "--model-name", default="qwen3-asr-1.7b-q8_0", help="传给 llama-server 的 model 字段"
    )
    parser.add_argument("--timeout", type=float, default=20.0, help="单段转写超时(秒)")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    ssl_context = build_ssl_context(args.cert, args.key, args.ca)
    transcriber = Transcriber(args.llama_server_url, args.model_name, args.timeout)

    async with websockets.serve(
        lambda ws: handle_connection(ws, transcriber),
        args.host,
        args.port,
        ssl=ssl_context,
        max_size=64 * 1024 * 1024,  # 单段最长 28s @16k*4B(见 AsrEngine VAD.maxSpeechDuration)留足余量
    ):
        mode = "mTLS(校验客户端证书)" if args.ca else "TLS(不校验客户端证书)"
        log.info("Qwen3-ASR 网关监听 wss://%s:%d,%s", args.host, args.port, mode)
        await asyncio.Future()  # 永久运行


if __name__ == "__main__":
    asyncio.run(main())
