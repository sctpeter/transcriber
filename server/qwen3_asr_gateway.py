#!/usr/bin/env python3
"""Qwen3-ASR-1.7B Q8 远程转写网关。

职责划分(见 docs/0003_remote_qwen3_asr_protocol.md):
  - 这个进程只负责"内网可达的 TLS(默认单向,--ca 可选升级成双向 mTLS)+
    WebSocket 面",不自己跑模型推理。
  - 真正的 ASR 推理交给 llama.cpp 的 llama-server(OpenAI 兼容的
    /v1/chat/completions 端点 + input_audio,与 /v1/audio/transcriptions 的内部
    改写逐字等价,但能逐请求传数值型采样参数,见 docs/0006),
    llama-server 只监听 127.0.0.1,不直接暴露给客户端——这样 mTLS 终止和模型服务
    分开,换模型/升级 llama.cpp 不用碰这层网关代码。

部署:
  1) 参照 server/README.md 起一个 llama-server(Qwen3-ASR-1.7B-GGUF, Q8_0)。
  2) 用 certs/make_remote_asr_certs.sh 签发这台机器的 server 证书。
  3) python3 qwen3_asr_gateway.py --cert ... --key ... --ca ...

协议:每个 WebSocket 连接上,客户端逐段发送
  1. 一条 TEXT 帧: {"type":"segment","id":N,"sample_rate":16000,"format":"pcm_s16le","num_samples":M}
     可选 "sampling":{"samplers":[...],"temperature":..,"top_k":..,"top_p":..,"min_p":..}
     (缺省 = 用 llama-server 默认采样;见 parse_sampling)
  2. 紧跟一条 BINARY 帧:M 个 int16 little-endian 采样
服务端处理完回一条 TEXT 帧:
  {"type":"result","id":N,"text":"..."} 或 {"type":"error","id":N,"message":"..."}
"""
from __future__ import annotations

import argparse
import asyncio
import base64
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
    """llama-server 对 Qwen3-ASR-1.7B-GGUF 的转写响应里(transcriptions 的 `text`
    与 chat/completions 的 `message.content` 相同),内容不是纯转写文本,而是 `language <lang><asr_text><转写内容>` 这种带标记
    的原始模型输出(2026-09-16 用 llama.cpp b10991 实测确认,不是文档行为,后续升级
    llama.cpp 需要重新验证这个格式)。这里只取 `<asr_text>` 之后的部分。
    """
    marker = "<asr_text>"
    idx = raw.find(marker)
    if idx == -1:
        return raw.strip()
    return raw[idx + len(marker) :].strip()


# llama.cpp common_chat_get_asr_prompt() 给非 LFM2 模板的固定 user 提示词。
# /v1/audio/transcriptions 内部就是把请求改写成 "这段文本 + 音频标记" 的 chat completion,
# 这里用 text + input_audio 两个 content part 拼出逐字相同的 prompt(b10991 源码 + 实测确认)。
ASR_USER_PROMPT = "Transcribe audio to text"


def build_chat_request(
    wav_bytes: bytes, model_name: str, sampling: dict[str, object] | None
) -> dict[str, object]:
    """构造发给 /v1/chat/completions 的 JSON body。

    为什么不用 /v1/audio/transcriptions:b10991 的 multipart 表单字段一律是字符串,
    该端点只把 temperature/max_tokens 转回数字,top_k 等会 400
    (`type must be number, but is string`)。JSON body 里数值类型原生保留。
    """
    body: dict[str, object] = {
        "model": model_name,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": ASR_USER_PROMPT},
                    {
                        "type": "input_audio",
                        "input_audio": {
                            "data": base64.b64encode(wav_bytes).decode("ascii"),
                            "format": "wav",
                        },
                    },
                ],
            }
        ],
    }
    if sampling:
        body["samplers"] = list(sampling["samplers"])
        for key in sampling["samplers"]:
            body[key] = sampling[key]
    return body


class Transcriber:
    """薄封装:把一段 WAV 转发给 llama-server 的 OpenAI 兼容 chat completion 端点。

    aiohttp 在方法内部才 import(而不是模块顶层):这样 build_ssl_context 这个
    纯 SSL 配置工具函数可以被 test/remote_asr_mock_server.py 复用,而不用逼着
    只想测证书握手的场景也装一份 aiohttp。
    """

    def __init__(self, llama_server_url: str, model_name: str, timeout: float):
        import aiohttp

        self.url = llama_server_url.rstrip("/") + "/v1/chat/completions"
        self.model_name = model_name
        self.timeout = aiohttp.ClientTimeout(total=timeout)

    async def transcribe(self, wav_bytes: bytes, sampling: dict[str, object] | None = None) -> str:
        import aiohttp

        body = build_chat_request(wav_bytes, self.model_name, sampling)
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            async with session.post(self.url, json=body) as resp:
                if resp.status >= 400:
                    # 把 llama-server 的错误原文带回客户端日志,而不是只剩一个状态码
                    raise RuntimeError(f"llama-server HTTP {resp.status}: {(await resp.text())[:300]}")
                data = await resp.json()
        content = data["choices"][0]["message"].get("content") or ""
        # content 不是纯转写文本,见 extract_asr_text 的注释
        return extract_asr_text(content)


def _strict_int(v: object) -> int:
    # int(20.7) 会静默截断、int(True) 会变 1,这两种都应当视为格式错误
    if isinstance(v, bool) or not isinstance(v, (int, float)) or int(v) != v:
        raise ValueError(f"不是整数: {v!r}")
    return int(v)


def parse_sampling(header: dict) -> dict[str, object] | None:
    """仅接受 App UI 暴露的采样器和值;没有 sampling 字段表示采用 llama-server 默认配置。

    白名单校验不能省:llama-server 对未知采样器名是静默忽略的(实测返回 200),
    不在这里拒绝的话客户端配错了谁都不会知道。temperature 必须在链里——缺了它
    llama.cpp 等价于温度 1 随机抽样(客户端 UI 也强制启用它)。
    """
    raw = header.get("sampling")
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise ValueError("sampling 必须是对象")
    allowed = ("top_k", "top_p", "min_p", "temperature")
    requested = raw.get("samplers")
    if not isinstance(requested, list) or not requested:
        raise ValueError("sampling.samplers 必须是非空数组")
    if len(requested) != len(set(requested)) or not set(requested) <= set(allowed):
        raise ValueError(f"sampling.samplers 包含不支持或重复的采样器: {requested}")
    if "temperature" not in requested:
        raise ValueError("sampling.samplers 必须包含 temperature")
    selected = [name for name in allowed if name in requested]
    try:
        values = {
            "samplers": selected,
            "temperature": float(raw["temperature"]),
            "top_k": _strict_int(raw["top_k"]),
            "top_p": float(raw["top_p"]),
            "min_p": float(raw["min_p"]),
        }
    except (KeyError, TypeError, ValueError) as e:
        raise ValueError("采样参数格式无效") from e
    if not 0 <= values["temperature"] <= 2 or not 0 <= values["top_k"] <= 200:
        raise ValueError("temperature 或 top_k 超出范围")
    if not 0 <= values["top_p"] <= 1 or not 0 <= values["min_p"] <= 1:
        raise ValueError("top_p 或 min_p 超出范围")
    return values


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
                text = await transcriber.transcribe(wav_bytes, parse_sampling(header))
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
