# Qwen3-ASR-1.7B Q8 远程转写服务端部署

两层架构(理由见 docs/0003):

```
Transcriber.app ──wss + 单向 TLS──▶ qwen3_asr_gateway.py ──http(127.0.0.1 only)──▶ llama-server
                                  (这个目录,认证/协议)      (真正跑 Qwen3-ASR 推理)
```

`llama-server` 只监听本机回环地址,不直接暴露给客户端;`qwen3_asr_gateway.py` 是唯一
对外（内网）暴露、由客户端用私有 CA 校验服务端身份的入口。换 ASR 模型/推理后端只需要改
`llama-server` 这一层,网关代码不用动。

## 1. 装 llama.cpp,起 Qwen3-ASR-1.7B Q8 的 llama-server

```bash
# 官方发布的 GGUF,Q8_0 量化(~2.17GB),WER 和 BF16 基本打平(见 docs/0003)
llama-server -hf ggml-org/Qwen3-ASR-1.7B-GGUF:Q8_0 \
    --host 127.0.0.1 --port 8080
```

验证:

```bash
curl http://127.0.0.1:8080/v1/audio/transcriptions \
    -F model=qwen3-asr-1.7b-q8_0 -F file=@some_16k_mono.wav
```

## 2. 签发这台机器的服务端证书

在**开发机**(不是这台服务器)上跑一次(见 `../certs/make_remote_asr_certs.sh`):

```bash
./certs/make_remote_asr_certs.sh init                       # 只需一次,生成私有 CA
./certs/make_remote_asr_certs.sh server <这台机器的域名或IP>
```

把生成的 `certs/server/server.{key,crt}` 和 `certs/ca/ca.crt` 拷到这台服务器上
(私钥 `server.key` 只给这台机器,`ca.crt` 两端都要,`ca.key` 谁都不给)。

## 3. 装依赖、起网关

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

python3 qwen3_asr_gateway.py \
    --host 0.0.0.0 --port 8765 \
    --cert /path/to/server.crt --key /path/to/server.key \
    --llama-server-url http://127.0.0.1:8080 \
    --model-name qwen3-asr-1.7b-q8_0
```

## 4. Transcriber 客户端配置

在 Transcriber 设置面板的"远程 ASR"里(或直接编辑 config.json 的 `remoteAsr` 段):

- 服务器地址:`wss://<这台机器的域名或IP>:8765/v1/transcribe`
  (路径部分网关代码不解析,写什么都行,写成这样只是约定)
- CA 根证书:同一个 `certs/ca/ca.crt`

## 已知限制(如实记录)

- 当前 Python TLS 1.3 / `websockets` 组合不能可靠在初始握手强制客户端证书校验，
  因此 mTLS 暂不支持。不要传 `--ca` 并把它当成访问控制；生产部署使用单向 TLS。

- Qwen3-ASR 本身(不管是 llama.cpp 还是其他推理后端)目前**不支持流式/分块增量输入**,
  只能整段 16kHz mono WAV 喂入——这也是为什么这个协议设计成"逐句请求/响应"而不是连续
  流式传输音频,和 Transcriber 本地 VAD 已经把音频切句的现状天然吻合。partial(实时预
  览文字)因此**继续走本地流式 paraformer**,不受这个开关影响,只有 final(整句精修)
  会走这条远程通道。
- `max_size=64MB` 是网关的 WebSocket 消息大小上限,对应 `AsrEngine.VAD.maxSpeechDuration`
  (默认 28s)的 16kHz int16 单声道音频留了很大余量,如果改大了 `maxSpeechDuration` 需要
  同步调这个上限。
- 网关和 llama-server 之间没有认证(纯 127.0.0.1 回环),这是有意的简化——如果 llama-server
  和网关不在同一台机器上,需要额外加一层(比如给 llama-server 也套一层 mTLS,或用
  ssh 端口转发),不在这次任务范围内。
