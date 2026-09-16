# Transcriber — macOS 实时语音转文字

Transcriber 是面向 Apple Silicon Mac 的本地实时转写 App。它可同时采集麦克风和系统音频，
在本地显示并持续写入转写结果；默认完全本地推理，也可把每个完整语句交给自建的远程
Qwen3-ASR 服务精修。

## 功能

- **双音源采集**：麦克风使用 `AVAudioEngine`；系统音频使用 ScreenCaptureKit。
- **实时 + 完整文本**：流式模型提供实时 partial 预览，VAD 判断一句结束后再生成 final 文本。
- **本地优先**：默认所有识别均在本机进行，不需要云服务或订阅。
- **可选远程精修**：final 文本可经 WSS 发给自建 Qwen3-ASR 网关；网络未连接、超时或服务端报错时自动回退本地，不丢句子。
- **可选音频预处理**：高通滤波与 DeepFilterNet3 降噪均默认关闭，可针对实际噪声单独启用和 A/B 测试。
- **可调配置与设置界面**：VAD、识别、降噪、模型路径、输出路径和远程 ASR 参数均可在设置中保存；下次开始录制即生效。
- **文本输出**：final 文本实时追加到本地文件，便于课后整理或交给其他工具处理。

## 从零构建

前置条件：Apple Silicon（arm64）Mac、macOS 14+、Xcode Command Line Tools；如需 DeepFilterNet3，
还需 Rust 与 `cargo-c`。

```bash
# 1. 下载 sherpa-onnx 的预编译库
./fetch_sherpa.sh

# 2. 构建 DeepFilterNet 的 C 动态库（需要 Rust；即使暂不启用降噪，当前 App 打包也需要它）
./fetch_deepfilter.sh

# 3. 一次性创建稳定的本机签名身份
./make_signing_cert.sh

# 4. 编译、组装、签名并启动 App
./build_app.sh --run
```

首次启动后，在 App 中点击“下载模型”。模型默认下载到
`~/Library/Application Support/Transcriber/models`，不打包进 `.app`。

### 构建产物与签名

`build_app.sh` 将可执行文件及依赖动态库组装为 `build/Transcriber.app`，再使用
`Transcriber Dev` 自签名身份签名。固定 bundle ID 与签名身份可使麦克风/屏幕录制的 TCC
授权跨构建保留；签名时 Keychain 会要求明确授权，脚本不会静默放行 `codesign` 使用私钥。
若未创建该身份，脚本会回退到 ad-hoc 签名，系统可能要求重新授权。

`third_party/`、`.build/`、`build/` 和证书产物均不进入版本控制。

## 使用与权限

- **麦克风**：首次录制时授予麦克风权限。
- **系统音频**：在“系统设置 → 隐私与安全性 → 屏幕录制”授权后，重启 App。
- **配置文件**：默认是 `~/Library/Application Support/Transcriber/config.json`；可用
  `TRANSCRIBER_CONFIG` 指向另一份配置。执行 `Transcriber --print-config` 可查看合并默认值后的实际配置。
- **模型目录**：可在设置中指定，或用 `TRANSCRIBER_MODELS` 临时覆盖。

## 远程 ASR（可选）

远程模式仅替换 final 精修，不影响本地实时 partial。**当前生产可用的认证模型是单向
TLS：客户端通过私有 CA 验证服务器。**虽然配置中保留了 `clientIdentityPath` 和网关的
`--ca` 参数，但在当前 Python TLS 1.3 / `websockets` 组合下，客户端证书不能在初始握手
被可靠强制校验；因此 mTLS 暂不支持，绝不能把客户端证书当作访问控制或身份认证依据。
证书生成脚本在 `certs/make_remote_asr_certs.sh`，网关部署说明在
[server/README.md](server/README.md)。

App 当前为支持私有 CA 的 WSS 服务设置了 `NSAllowsArbitraryLoads`，即关闭 **Transcriber
自身** 的 ATS 附加限制；这不会影响系统或其他 App。远程端点仍必须使用 `wss://`，并通过
应用内私有 CA 校验。排查经过见 [docs/0004_remote_asr_ats_resolution.md](docs/0004_remote_asr_ats_resolution.md)。

设置页可选“覆盖服务器默认采样器”（top-k / top-p / min-p，温度始终启用）。配置坑：

- **llama-server b10991 的 `/v1/audio/transcriptions` 不能逐请求传 top_k/top_p/min_p。**
  multipart 表单字段一律是字符串，该端点只把 `temperature`、`max_tokens` 转回数字，其余报
  `type must be number, but is string`（HTTP 400）。网关因此改走 `/v1/chat/completions` +
  `input_audio`（prompt 与 transcriptions 端点逐字等价），详见 [docs/0006](docs/0006_remote_qwen_sampling.md)。
- **llama-server 对未知采样器名静默忽略**（仍返回 200），所以网关必须做白名单校验。
- 服务器默认温度约 1e-6（近似贪心），App 默认值与之对齐为 0；采样链里不含 temperature 时
  llama.cpp 等价于温度 1 随机抽样，所以覆盖时强制启用温度。
- **移动项目目录后要检查 `config.json` 里的证书路径**（如 `remoteAsr.caCertPath`）。它是绝对路径，
  文件找不到时 App 不报错弹窗，只会一直回退本地精修。
- **Python 3.13 客户端连网关会报 `Missing Authority Key Identifier`**：3.13 默认启用
  `VERIFY_X509_STRICT`，`make_remote_asr_certs.sh` 签出的证书不满足；App（macOS SecTrust）不受影响，
  Python 测试客户端需清掉该 flag（见 `test/remote_gateway_e2e.py`）。

## 项目模块

```text
Sources/
├── CSherpaOnnx/                 # sherpa-onnx C API 的 SwiftPM system library
├── CDeepFilter/                 # DeepFilterNet C API 的 SwiftPM system library
└── Transcriber/
    ├── TranscriberApp.swift      # App 与无头自测入口
    ├── AppState.swift            # UI 状态、录制生命周期和管线装配
    ├── Config.swift              # 配置读取、保存与默认值合并
    ├── TranscriptWriter.swift    # final 文本追加写入
    ├── SelfTest.swift            # 无头诊断与自测入口
    ├── Capture/                  # 麦克风、系统音频采集
    ├── Audio/                    # 下混、高通、DeepFilterNet、重采样、WAV
    ├── ASR/                      # 模型、VAD、流式/离线识别、远程精修
    └── UI/                       # 主窗口、菜单栏、设置与文本视图

server/                           # WSS 网关和部署运行手册
certs/                            # 证书生成脚本（生成物被忽略）
test/                             # 配置、降噪、远程 ASR 自动化测试
docs/                             # 设计决策、协议与排查记录
```

主数据流：

```text
麦克风 / 系统音频
  → 可选预处理（高通、DeepFilterNet3）
  → 16 kHz 单声道重采样
  → VAD 分段
  → 本地流式 partial
  → 本地或远程 final 精修
  → UI 与文本文件
```

## 测试

```bash
./test/test_config.sh       # 默认值、部分配置覆盖与配置隔离
./test/test_denoise.sh      # 高通与降噪的降级保护
./test/test_remote_asr.sh   # 私有 CA、WSS、远程协议和本地回退
uv run --with websockets python test/test_gateway_sampling.py  # 网关采样参数校验与请求字段类型
./test/test_remote_sampling_live.sh  # 真实远端：新网关代码直连 llama-server（不动已部署服务）
uv run --with websockets python test/remote_gateway_e2e.py <wss_url> certs/ca/ca.crt <16k.wav>  # 部署后端到端
```

完整的配置设计、降噪取舍和远程协议分别见 `docs/0001`、`docs/0002`、`docs/0003`。
