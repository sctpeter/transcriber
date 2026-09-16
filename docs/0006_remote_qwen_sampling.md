# 远程 Qwen 采样参数（完成 0005）

承接 [0005](0005_remote_qwen_sampling_plan.md)。本文记录阻塞点的调查结论、最终实现和测试。

## 调查结论（llama.cpp b10991，commit 930e2fa59）

1. **transcriptions 端点不支持逐请求数值采样参数。** `server-http.cpp` 把 multipart
   文本字段全部转成 JSON 字符串；`convert_transcriptions_to_chatcmpl()` 只把 `temperature`、
   `max_tokens`（和 `stream`）转回正确类型，`top_k` 等原样当字符串透传，因此 400。
   该版本无 `/openapi.json`（404），也不接受 JSON body 上传文件（文件只从 multipart 取）。
2. **transcriptions 本质就是 chat completion。** 内部 user 消息为
   `common_chat_get_asr_prompt()` 的 `"Transcribe audio to text"` + 媒体标记（非 LFM2 模板，
   无 system）。chat completion 里 `text` part + `input_audio` part 拼接时媒体标记前不加换行，
   得到逐字相同的 prompt。
3. **远端实测（wangtian03，/tmp/test.wav）**：
   - transcriptions 与 chat 默认参数输出完全一致，`extract_asr_text()` 无需修改；
   - chat 覆盖 `samplers/top_k/top_p/min_p/temperature` 后，`/slots` 显示对应 slot 采用了覆盖值，
     另一个 slot 保持默认，不串请求；
   - 未知采样器名（如 `"nope"`）被**静默忽略**，仍 200；
   - 服务器默认：temperature≈1e-6、top_k 40、top_p 0.95、min_p 0.05，默认链
     `penalties;dry;top_n_sigma;top_k;typ_p;top_p;min_p;xtc;temperature`；
   - temperature 0 与 1e-6 输出一致。

结论：保留 0005 的 Swift/UI/协议方案，只把网关改为 `/v1/chat/completions`，不需要升级
llama.cpp，也不需要重启 llama-server。

## 用户决定（2026-09-16）

- UI 默认值对齐服务器：temperature 0、top_k 40、top_p 0.95、min_p 0.05。
- 覆盖时**强制启用 temperature**：链里没有 temperature 时 llama.cpp 等价于温度 1 随机抽样。

## 实现

- `Config.swift`：`Sampling.order` 固定顺序；`effectiveSamplers` 按顺序去重并总是带
  temperature（旧 config.json 漏了也会补上）；默认值如上。
- `SettingsView.swift`：多选框只剩 top-k/top-p/min-p，温度数值框始终显示；勾选写回时规范化顺序。
- `RemoteAsrRefiner.swift`：header 的 `sampling.samplers` 取 `effectiveSamplers`。
- `server/qwen3_asr_gateway.py`：
  - 新增纯函数 `build_chat_request()`，构造 JSON body（base64 WAV + 数值类型采样字段，
    只发送选中的采样器对应的值）；`Transcriber` 改 POST `/v1/chat/completions`，读
    `choices[0].message.content`；HTTP 错误把 llama-server 返回原文带进 error 帧。
  - `parse_sampling()`：修复重复项未被拒绝的 bug；要求包含 temperature；top_k 必须是真整数
    （拒绝 20.7 / true / "20"）。校验失败 → 该 segment 回 error 帧 → 客户端回退本地精修并记录日志。

## 测试

| 测试 | 内容 | 结果 |
|---|---|---|
| `uv run --with websockets python test/test_gateway_sampling.py` | 空 sampling 不覆盖；顺序规范化；未知/重复/缺温度/越界/非整数被拒；最终 JSON 字段类型为 number | 12/12 |
| `./test/test_config.sh` | 新增：旧 JSON 缺 sampling 回落默认；sampling 写出读回一致 | 24/24 |
| `./test/test_remote_asr.sh` | 原有 TLS/协议/回退回归 | 4/4 |
| `uv run --with websockets python test/remote_gateway_e2e.py <wss> certs/ca/ca.crt <wav>` | 部署后：本机 WSS 经已部署网关的默认/覆盖/非法采样 | 通过 |
| `./test/test_remote_sampling_live.sh` | 把新网关代码拷到 wangtian03 临时目录，直连真实 llama-server：默认与覆盖均得到可解析文本，`/slots` 确认覆盖值生效 | 通过 |

未覆盖：Swift 客户端实际发出的 `sampling` header 没有端到端断言（mock 网关不检查 header），
由 `effectiveSamplers` 的逻辑 + 网关校验兜底；部署后 GUI 真实转写时确认。

## 部署（2026-09-16 已完成）

1. `./build_app.sh`：签名身份 `Transcriber Dev`，`codesign --verify --strict` 通过，Info.plist ATS 配置在。
2. 正常退出旧 App → 旧版移到 `build/Transcriber.app.prev_20260916_082245` → `ditto` 新版到
   `/Applications/Transcriber.app` → 签名校验通过。
3. 网关：远端备份 `~/transcriber_server/qwen3_asr_gateway.py.bak_20260916_082222` → 复制新版 →
   `pm2 restart qwen3-asr-gateway`（llama-server 未重启）→ 8765 正常监听。
   回滚：把 .bak 文件拷回原名后再 `pm2 restart qwen3-asr-gateway`。
4. 端到端 `test/remote_gateway_e2e.py`（本机 WSS → 已部署网关 → llama-server）：默认、覆盖都返回
   正确文本且一致；非法采样器收到 error 帧。

部署时发现：本机 `config.json` 的 `remoteAsr.caCertPath` 还指向项目搬迁前的
`.../claude_home/transcriber/certs/ca/ca.crt`（已不存在），App 会因此连不上远程、一直回退本地。
