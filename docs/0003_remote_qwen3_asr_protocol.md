# 0003 远程 Qwen3-ASR-1.7B Q8 精修通道

## 背景

现有的"final(整句精修)"由本地常驻的 sherpa-onnx paraformer-large 做。评估后决定:
如果换成 Qwen3-ASR-1.7B Q8,不建议默认加通用降噪(见 `docs/0002` 的结论),但可以把
"精修"这一步换成部署在远程服务器上的 Qwen3-ASR,通过网络调用——本地流式 paraformer
继续负责 partial(实时预览),不受影响。这份文档记录协议设计和踩过的坑。

## 为什么是"逐句请求/响应"而不是连续流式

调研确认(见下方 Sources):
- Qwen3-ASR-1.7B 官方发布了 GGUF 格式,Q8_0 量化 ~2.17GB,和 BF16 精度基本打平。
- 主流部署方式是 `llama.cpp` 的 `llama-server`,它本来就有 OpenAI 兼容的
  `/v1/audio/transcriptions` 端点。
- 输入约定是**完整的 16kHz mono WAV**,官方工具链(`transcribe-cli`/`transcribe.cpp`)
  明确写了"不支持分块/流式处理,只能整段喂"。

这和 Transcriber 现有架构天然吻合:VAD 已经把音频切成一句一句的完整语音段
(`AsrEngine.drainSegments()`),"精修"这一步本来就是拿一整段音频去 decode,不是增量
喂——所以协议不需要设计成"边说边发音频流",而是"VAD 判完一句,整句音频发一次,等
一个结果回来",简单很多,也不需要在服务端做增量拼接。

## 两层架构

```
Transcriber.app(Swift, RemoteAsrRefiner)
    │ wss:// + 私有 CA 校验服务端证书（当前为单向 TLS）
    ▼
qwen3_asr_gateway.py(Python, server/)  ── 只做协议/认证,不跑模型
    │ http://127.0.0.1:8080(仅回环,不对外)
    ▼
llama-server(llama.cpp, OpenAI 兼容 /v1/audio/transcriptions)  ── 真正跑 Qwen3-ASR 推理
```

分两层是为了让"要不要认证/怎么认证"和"用什么跑模型"解耦——换推理后端(比如以后
换 vLLM)只需要改 `qwen3_asr_gateway.py` 里 `Transcriber.transcribe()` 一个方法,
Swift 客户端和协议本身不用动。

## 线上协议

单条 WebSocket 连接(建立一次,整个录制会话复用),逐段收发:

**客户端 → 服务端**(每句一组,两条消息紧挨着发):
1. TEXT 帧,JSON:
   ```json
   {"type": "segment", "id": 42, "sample_rate": 16000, "format": "pcm_s16le", "num_samples": 24000}
   ```
2. BINARY 帧:`num_samples` 个 int16 little-endian PCM 采样(单声道,和 header 里的
   `sample_rate` 对应,固定 16000——和现有管线的重采样目标一致)。

**服务端 → 客户端**:
```json
{"type": "result", "id": 42, "text": "识别出来的文字"}
```
或
```json
{"type": "error", "id": 42, "message": "出错原因"}
```

`id` 是客户端维护的单调递增计数器,服务端原样回传用于配对——同一条连接上请求基本
是顺序处理的,但客户端不假设这一点(见下面"顺序保证")。

## 认证：当前为单向 TLS，不用系统信任库

`certs/make_remote_asr_certs.sh` 生成一个私有 CA 和服务端证书（也保留客户端证书生成
能力）。选择自建 CA 而不是接商业 CA 或用系统信任库，原因：
- 这是内部通道(Transcriber 客户端 ↔ 自己部署的推理服务器),不是对公网用户的服务,
  不需要浏览器/系统级信任。

当前生产部署**不支持 mTLS**：在当前 Python TLS 1.3 / `websockets` 组合下，
`CERT_REQUIRED` 不能可靠地在初始握手强制校验客户端证书。`clientIdentityPath` 与服务端
`--ca` 因而不能作为访问控制或身份认证依据；默认部署不传 `--ca`，只做客户端校验服务端。

Swift 端(`RemoteAsrRefiner` 的 `URLSessionDelegate`):
- `NSURLAuthenticationMethodServerTrust`:不用系统信任评估,用
  `SecTrustSetAnchorCertificates` + `SecTrustSetAnchorCertificatesOnly(true)` 只信
  配置里指定的那一个 CA 证书,再 `SecTrustEvaluateWithError` 校验服务端证书链。

客户端证书相关配置仅为将来实现可靠 mTLS 预留，当前不构成安全边界。

## fail-open:远程不可用不能丢句子

`RemoteAsrRefiner` 包一个本地 `OfflineRefiner` 作为兜底,以下任一情况都会自动回退本
地精修,回退后 UI 上这一句的效果和"没开远程 ASR"完全一样(只是慢一点,多算了一次
本地精修):
- 连接尚未建立/已断开(`refine()` 调用时检查 `connected`)。
- 单段超过 `remoteAsr.timeoutSeconds`(默认 8s)没收到结果。
- 服务端返回 `{"type": "error", ...}`。

断线后台自动重连,指数退避(1s → 2s → 4s → … 封顶 30s),连上一次就把退避重置。

## 顺序保证

`final` 文本必须按 VAD 分段的时间顺序上屏,不能因为网络原因乱序。`RemoteAsrRefiner`
内部维护一个按 `refine()` 调用顺序排队的 FIFO(`order` 数组):不管远程结果是按什么
顺序回来的、也不管某一段是走远程成功还是超时回退到本地,`completion` 永远严格按入队
顺序依次触发——排在前面的段落结果没到,后面的段落即使已经算完也会被压住,等前面的
先出。这是刻意的设计取舍:宁可让后面那句的 UI 更新延迟一点,也不接受文字顺序错乱。

## 已知限制

- Qwen3-ASR 本身不支持流式增量输入,所以远程通道只覆盖 final,不覆盖 partial——这
  是模型能力的硬限制,不是协议设计的取舍空间。
- 网关和 `llama-server` 之间没有认证(假设同机部署,只走 127.0.0.1),如果要分开部署
  需要额外加一层,见 `server/README.md`。
- 当前 Python 网关不能可靠实现 mTLS；不要依赖客户端证书限制谁能连接。
- `.p12` 密码目前明文存在本地 `config.json` 里,权限等同本机磁盘访问权限,和现有
  `config.json` 存其他配置的安全模型一致(没有做操作系统 Keychain 集成,这是明确的
  范围裁剪,不是遗漏)。

## 测试

`test/test_remote_asr.sh`:起一个本地假的 TLS WebSocket 服务端(纯 Python,固定回复
一个已知文本,不需要真的部署 llama-server/下载 Qwen3-ASR 模型),验证:
1. `certs/make_remote_asr_certs.sh` 生成的证书链自签自验通过。
2. Swift 客户端用生成的证书能连上、发一段音频、收到匹配的 `result`。
3. 证书不匹配(客户端用另一套 CA 签的证书)时握手应该被拒绝,`RemoteAsrRefiner`
   fail-open 回退到本地精修(用一个不会真正 decode 出文字的哑 `OfflineRefiner`
   替身[^1]验证"没有因为网络问题崩溃或卡死"这一点,不验证真实识别准确率)。

真实 Qwen3-ASR 推理效果(WER、和本地 paraformer-large 的对比)需要真机部署,不在自动
化测试范围内。

自动化测试可验证本地 mock 下的客户端证书行为，但这不等同于生产网关具备可靠 mTLS。
当前生产安全边界仅为服务端身份的私有 CA 校验；客户端身份认证待采用可可靠强制校验的
方案后再启用。

[^1]: 受限于 `OfflineRefiner` 是具体类(依赖真实 sherpa-onnx 模型文件),这条用例里
    validate 的是"网络层 fail-open 触发了",没有替换掉本地精修本身,详见测试脚本注释。

## Sources

调研 Qwen3-ASR-1.7B 部署方式时查阅的资料:
- https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF
- https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/qwen3-asr-1.7b.md
- https://docs.vllm.ai/projects/ascend/en/latest/tutorials/models/Qwen3-ASR-1.7B.html
