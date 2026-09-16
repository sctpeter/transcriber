# 移除本地“解码策略”选项，固定 greedy_search

## 问题

设置页“本地识别性能”提供 `greedy_search` / `modified_beam_search` 两个解码策略。选择
`modified_beam_search` 后点击“开始转写”，App 直接退出：

- 系统日志：`termination reported by launchd (0, 0, 65280)`，即退出码 255、`voluntary`，无崩溃报告；
- 复现（无头 `--selftest`，同一份配置）：sherpa-onnx 打印
  `offline-recognizer-paraformer-impl.h ... Only greedy_search is supported at present. Given modified_beam_search`
  后在 C++ 内 `exit(-1)`，Swift 侧无法捕获。

## 原因

本地流式与离线精修模型都是 paraformer（非自回归：先预测字数，再一次并行输出所有位置）。
beam search 需要逐步生成、每步依赖已选 token 的结构（transducer 等），paraformer 没有可展开的
搜索路径，sherpa-onnx 只实现了 greedy_search。该选项对当前模型没有意义。

## 决定（2026-09-16，用户确认）

去掉该选项，固定 greedy_search。若以后需要 beam search / 热词，需另行引入 Zipformer transducer
模型并评估中文准确率（未做）。

## 实现

- `Config.swift`：删除 `ASR.decodingMethod`。旧 `config.json` 中残留的该键在解码时被忽略，
  下次保存设置时自然清除——不存在“回退”，因为不再有可选项。
- `AsrEngine.swift`：在线/离线识别器均显式传 `"greedy_search"`。
- `SettingsView.swift`：移除 Picker，说明文字标明“解码:greedy_search(paraformer 仅支持此项)”。

## 测试

| 测试 | 内容 | 结果 |
|---|---|---|
| `./test/test_decoding_greedy.sh` | 旧配置含 `modified_beam_search`：selftest 正常退出、sherpa-onnx 未收到该值、识别出 `say` 合成语音；`--print-config` 不再含该字段 | 4/4 |
| `./test/test_config.sh` | 默认值断言更新为“decodingMethod 已移除” | 24/24 |
