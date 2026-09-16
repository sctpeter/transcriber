# 远程 Qwen 采样参数：实现与部署交接计划

> **状态（2026-09-16）**：阻塞点已解决，实现与测试已完成，见
> [0006_remote_qwen_sampling.md](0006_remote_qwen_sampling.md)。下文保留为当时的交接记录。

## 目标

在 Transcriber 的设置页增加**远程 Qwen3-ASR**采样配置，并让它写入
`~/Library/Application Support/Transcriber/config.json`；每段音频请求读取会话启动时的配置，
通过 WebSocket 发至网关，再由网关以当前 llama-server 支持的方式应用。

设置页还需：

- 删除面向用户的“见 docs/…”提示；App 内不应要求用户阅读源码文档。
- 将“识别性能”清楚区分为“本地 sherpa-onnx”与“远程 Qwen3-ASR”。

## 已确认的产品决定

1. 本地 `asr.numThreads`、`asr.decodingMethod` 只影响本地实时 partial 与本地 final；必须在 UI明示，不影响远程 Qwen。
2. 远端 UI 只暴露采样相关参数：多选采样器、温度、top-k、top-p、min-p。
3. 采样器以多选框呈现，按固定顺序执行：`top_k` → `top_p` → `min_p` → `temperature`。
   对应数值框仅在该规则被勾选时出现。
4. 未启用“覆盖服务器默认采样器”时，不发送任何采样覆盖，保留服务器默认值。
5. mTLS 当前不可靠，不能作为认证或访问控制；远程通道当前是单向 TLS + 客户端私有 CA
   校验服务器。

## 已完成但尚未部署的本地改动

工作目录现在是 `/Users/peter/Desktop/claude_home`（项目被从原来的 `transcriber/` 子目录
移回此目录）。以下文件已有未部署改动：

- `Sources/Transcriber/UI/SettingsView.swift`
  - 已删两个 Section 标题中的 `见 docs/...`。
  - 已将本地性能区改为“本地识别性能（sherpa-onnx）”，并增加“仅影响本地”说明。
  - 已新增 `RemoteSamplingSettings` 和 `NumberField`；其中“覆盖服务器默认采样器”开关默认
    勾选时选中四项采样器。
- `Sources/Transcriber/Config.swift`
  - 已新增 `RemoteAsr.Sampling`：`samplers`、`temperature`、`topK`、`topP`、`minP`；支持旧
    `config.json` 缺字段时回落默认值。
- `Sources/Transcriber/ASR/RemoteAsrRefiner.swift`
  - 已将选中的采样器和值放入每段 WebSocket JSON header 的 `sampling` 对象。
- `server/qwen3_asr_gateway.py`
  - 已新增 `parse_sampling()`，白名单校验采样器和值域。
  - 已尝试将采样参数以 multipart 表单字段转发给 `/v1/audio/transcriptions`。

本地 `swift build` 通过；`parse_sampling()` 的本地 Python 验证通过；尚未构建/安装 release App，
也尚未复制或重启远端网关。

## 阻塞点：当前 multipart 编码不兼容

在 `wangtian03` 实测当前服务：

- llama-server：`0.4.1-dev (build 10991, commit 930e2fa59)`。
- 实际运行参数：`--ctx-size 4096 --parallel 2`；未显式设置线程数或采样参数。
- `--help` 显示支持：`--samplers`、`--temperature`、`--top-k`、`--top-p`、`--min-p`。
- 用 curl 对 `/v1/audio/transcriptions` 发送 multipart：

  ```bash
  -F 'samplers=top_k;top_p;min_p;temperature' -F top_k=20 -F top_p=0.9 \
  -F min_p=0.05 -F temperature=0.2
  ```

  返回 HTTP 400：`Field 'top_k': type must be number, but is string`。

原因是 `aiohttp.FormData` 的普通 multipart 字段编码为字符串，而该版本 llama-server 的转写
端点要求 JSON number。不能把当前网关改动直接部署，否则用户启用覆盖参数后请求会失败。

## 推荐后续路线

### 第一步：确认 b10991 转写 API 的正确请求格式

在 `wangtian03` 上查询 `http://127.0.0.1:8080/openapi.json`，重点检查
`/v1/audio/transcriptions` 的 request body/schema；或查看该版本 llama.cpp 源码的 endpoint 实现。

需要确认以下之一：

1. 是否支持 JSON body 中的文件/base64 与数值采样参数；
2. 是否支持把参数作为 URL query 参数（使其按数值解析）；
3. 是否存在特定 multipart JSON part 的格式；
4. 若接口完全不支持逐请求采样参数，则不能做每个 App 的 UI 覆盖。

### 第二步：根据结果选实现

- **若支持逐请求数值参数**：修正 `Transcriber.transcribe()` 的编码，并增加真实接口回归测试；
  保留现有 Swift/UI/协议方案。
- **若只支持进程级 CLI 参数**：不要假装逐请求可调。UI 应改为只显示服务器当前参数（只读），
  或另做受认证保护的服务器管理接口；不能让普通客户端直接改共享推理服务。
- **若需要升级 llama.cpp**：先在测试环境验证 Qwen3-ASR 输出格式仍兼容
  `extract_asr_text()`，再决定升级和部署窗口。

## 测试要求

1. `swift build`：设置页与新 Codable 配置编译通过。
2. 扩展 `test/test_config.sh`：验证旧 JSON 能加载；保存后 `remoteAsr.sampling` 完整写入并读回。
3. 为网关新增 Python 测试：
   - 空 `sampling` 不覆盖默认；
   - 合法选择按固定顺序规范化；
   - 未知采样器、重复项、越界数值被拒绝；
   - 验证最终发给 llama-server 的字段类型符合已确认接口。
4. 真实远端测试：默认设置、至少一个覆盖设置都返回 HTTP 200 与可解析的转写文本。
5. `./test/test_remote_asr.sh` 保持通过。

## 部署步骤（仅在真实接口验证通过后）

1. 本机执行 `./build_app.sh`；新的 Keychain 配置会要求明确授权 `codesign`。
2. 验证 `build/Transcriber.app` 的签名和 `Info.plist` 中 ATS 配置，然后替换
   `/Applications/Transcriber.app`。
3. 复制更新后的 `server/qwen3_asr_gateway.py` 到
   `wangtian03:~/transcriber_server/qwen3_asr_gateway.py`；先在远端保留带时间戳的备份。
4. 使用 `pm2 restart qwen3-asr-gateway` 重启网关（会短暂中断远程 final 精修；客户端应显示
   回退本地）。不要重启 llama-server，除非 API 兼容性方案需要它。
5. 检查 `pm2 status` 与 gateway 日志，做一次 GUI 真实转写。

## SSH 会话

本次使用的 tmux 会话名为 `ssh_wangtian03`，已登录普通用户并保持打开；可继续复用。
