# 0001 统一配置系统

## 背景

改造前,VAD 阈值、静音断句时长、识别线程数、解码策略、模型/输出目录等参数都是散落在
`AsrEngine.swift`/`AsrModels.swift`/`AppState.swift` 里的字面量,改一个参数要改 Swift
代码、重新编译、重新签名打包才能生效。

## 方案

- 新增 `Sources/Transcriber/Config.swift`:`TranscriberConfig`(vad / asr / paths 三段)
  + `ConfigStore`(load/save)。默认值 = 改造前的硬编码值,行为不变。
- 落盘位置:`~/Library/Application Support/Transcriber/config.json`(与已有的
  `models/` 目录同级),不进 `.app` bundle——`build_app.sh` 每次 `rm -rf` 重建 bundle,
  放进 bundle 的文件必然被清空。可用 `TRANSCRIBER_CONFIG` 环境变量覆盖路径(测试/多套
  参数用,与已有的 `TRANSCRIBER_MODELS` 同思路)。
- JSON 支持**部分覆盖**:只写你想改的字段,没写的字段自动落到默认值(自定义
  `init(from:)` + `decodeIfPresent(...) ?? default`),避免"改一个参数就得把整份
  config 抄一遍"。
- 生效时机:`AppState.startRecording()` 每次开始转写都会重新读盘一次并重建
  `AsrEngine`/`OfflineRefiner`(它们本来就是每次录制新建),所以改完设置后**下次点
  "开始转写"就生效**,不需要重启 App、更不需要重新编译。
- 新增设置面板 `UI/SettingsView.swift`(SwiftUI `Settings` scene,Cmd+, 打开,
  ContentView 右下角齿轮按钮也能进):VAD 阈值/静音时长/最短语音/单句上限/窗口大小、
  识别线程数/解码策略、模型目录与录音输出目录(带 NSOpenPanel 选择 + 恢复默认)。
- 新增 `--print-config` 诊断入口:打印当前生效配置文件路径 + 合并后的完整 JSON,
  方便确认"改动到底生效了没"。

## 未纳入 config 的部分

- 采样率(16000,VAD/重采样器强绑定,改了会破坏管线)、模型文件名/下载 URL(绑定
  具体模型版本,换模型是更大的改动,不算"调参")、UI 观感类字面量(窗口大小/字号/
  电平表节流间隔)——按需求讨论后明确排除,避免为不需要调的东西增加心智负担。
- 流式识别器的 `modelType` 必须留空(显式设值会导致 encoder 状态初始化不完整,
  ORT 报 `GetElementType is not implemented`,2026-07-02 实测过),不可配置。

## 测试

`test/test_config.sh`:验证默认值与改造前硬编码值一致、部分覆盖 JSON 正确合并
(覆盖字段生效+未覆盖字段落默认值)、`TRANSCRIBER_CONFIG` 隔离不污染真实 App
Support 状态。另外用 `say` 生成的合成语音跑过一遍 `--selftest`,确认新参数链路
（AsrModels → AsrEngine/OfflineRefiner → AsrPipeline）没有破坏原有识别流程。
