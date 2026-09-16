# Third-Party Notices

本项目自身代码以 [MIT License](LICENSE) 发布。以下第三方内容适用其各自的许可证，**不受** MIT 许可覆盖。

## 随仓库分发的第三方源码

### sherpa-onnx Swift API

- 文件：`Sources/Transcriber/ASR/SherpaOnnx.swift`
- 来源：[k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) v1.13.3，
  `swift-api-examples/SherpaOnnx.swift`
- 版权：Copyright (c) 2023 Xiaomi Corporation
- 许可证：Apache License 2.0，全文见 [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt)
- 修改：在文件开头加入 `import CSherpaOnnx`（本项目 SwiftPM 模块），删除上游第 1015 行之后的
  内容（TTS 等本项目未使用的 API）；保留部分未作其他改动。

## 构建或运行时下载、不随仓库分发的依赖

以下内容由脚本或 App 在本地下载，不包含在本仓库中；使用时请遵守各自的许可证。

| 依赖 | 获取方式 | 许可证 |
|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 预编译库（含 onnxruntime） | `fetch_sherpa.sh` | Apache-2.0（onnxruntime 为 MIT） |
| sherpa-onnx ASR 模型（paraformer 等） | App 内 `ModelDownloader` | 见各模型发布页 |
| [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) | `fetch_deepfilter.sh` 本地编译 | MIT / Apache-2.0 双许可 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp)（服务端） | `server/RUNBOOK.md` 中下载 | MIT |
| Qwen3-ASR 模型（服务端） | `server/RUNBOOK.md` 中下载 | 见模型发布页 |
| Python 包 `websockets`、`aiohttp`（服务端） | `server/requirements.txt` | BSD-3-Clause / Apache-2.0 |
