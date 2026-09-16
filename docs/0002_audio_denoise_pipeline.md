# 0002 可选降噪预处理(高通 + DeepFilterNet3)

## 背景

现有链路里没有任何显式降噪:采集 → 显式重采样(48k→16k)→ VAD → 两遍识别,唯一带
"滤波"性质的环节是重采样器内部为抗混叠而带的低通,不是为降噪设计的。评估后确认
Qwen3-ASR 这类端到端大模型 ASR 本身训练时已覆盖大量真实噪声场景,给它接一个独立训
练的深度降噪网络有分布不匹配、伤可懂度的风险,所以这里不默认开启任何降噪,只是把
"高通滤波"和"DeepFilterNet3"做成两个**默认关闭**的可选开关,方便针对具体噪声场景
做 A/B 测试,而不是把降噪写死进管线。

## 方案

### 插入点:原生采样率,重采样之前

```
采集 buffer(原生格式,任意声道数)
  → AudioPreprocessor(可选):下混单声道 → [高通] → [DeepFilterNet3]
  → StreamingResampler(照常显式重采样到 16k,不变)
  → VAD → 两遍识别(不变)
```

DeepFilterNet3 的模型固定按 48kHz 训练/导出(`libDF/src/capi.rs` 里 `df_create` 内
部写死 `channels=1`,采样率由 tar.gz 里的 config.ini 决定、默认发布的
`DeepFilterNet3_onnx.tar.gz` 是 48kHz),所以必须插在重采样之前;麦克风原生格式和
系统音频(`SCStreamConfiguration.sampleRate = 48000`,已有代码写死)通常正好是
48kHz,这也是为什么"只加一次重采样"的原则在这里没被破坏——降噪本身不引入新的采样
率转换。

新增 `Sources/Transcriber/Audio/`:
- `HighPassFilter.swift`:标准 RBJ biquad 二阶高通(Q=0.707,Butterworth),纯 Swift
  实现,无外部依赖,跨 buffer 保留滤波器状态。默认截止 80Hz。
- `DeepFilterNetDenoiser.swift`:包一层 DeepFilterNet 官方 `libdf` C API
  (`Sources/CDeepFilter` systemLibrary,镜像 `CSherpaOnnx` 的写法)。按
  `df_get_frame_length()` 返回的帧长做内部缓冲,喂任意长度 chunk、按帧调用
  `df_process_frame`。
- `AudioPreprocessor.swift`:编排下混单声道 + 高通 + DeepFilterNet3,两个开关都关时
  返回 `nil`,调用方零开销跳过。任一环节初始化失败都是 **fail-open**(跳过该环节,
  不阻断录音)。

`AsrPipeline.process(buffer:)` 在 `StreamingResampler` 之前插入这一层,`AsrPipeline`
初始化时用完整 `TranscriberConfig` 构造 `AudioPreprocessor`(懒加载,和 resampler 一
样在第一个 buffer 到达时才建,因为需要知道原生格式)。

### `Sources/CDeepFilter` 与 `fetch_deepfilter.sh`

DeepFilterNet upstream 的 GitHub Releases 只发布 `deep-filter` CLI 和 LADSPA 插件
(`libdeep_filter_ladspa-*.dylib`)的预编译产物,**没有发布 `capi.rs` 对应的 C ABI
库**——`libDF/Cargo.toml` 里的 `[package.metadata.capi.*]` 段是留给 `cargo-c` 工具本
地编译用的。所以这里和 `fetch_sherpa.sh`(下载预编译包)不同,`fetch_deepfilter.sh`
是**本地编译**:clone 仓库 → `cargo capi build --release --features capi` → 产物拷到
`third_party/deepfilternet/{lib,include}`。需要本机装 Rust 工具链
(`cargo install cargo-c`)。

模型文件 `DeepFilterNet3_onnx.tar.gz`(仓库 `models/` 目录下,~7.6MB)不随
`cargo capi build`产出,`fetch_deepfilter.sh` 会额外把它从 clone 下来的仓库里复制
出来;`AudioPreprocessor` 按 `AsrModels.searchPaths` 同一套目录(`TRANSCRIBER_MODELS`
→ `config.paths.modelsDir` → App Support/Transcriber/models)找同名文件,设置面板里
也可以手填绝对路径覆盖。

### Config

`TranscriberConfig.denoise`:
- `highPass.{enabled, cutoffHz}`,默认关闭、80Hz。
- `deepFilterNet.{enabled, attenLimitDb, modelPath}`,默认关闭、30dB、`modelPath`
  留空走自动查找。

### 已知的上游限制(如实记录,不是我们代码的 bug)

`libdf` 的 `df_create` 在 tar.gz **存在但内容损坏**时(`DfParams::new(...).expect(...)`)
是 Rust panic 跨 FFI 边界直接 abort 整个进程,不是可捕获的错误。我们这边的防御只能
挡住"文件不存在"这一类(先 `FileManager.fileExists` 检查再调用),挡不住"文件存
在但损坏"。这是 DeepFilterNet 官方 C API 本身的行为,不是能在 Swift 侧修的东西,决
定要不要在生产环境启用这个开关时应该把这条风险算进去。

## 未纳入的部分

- 两个开关都**默认关闭**,不改变现有识别行为。是否要为某个具体噪声场景打开,建议
  按 `docs/0003` 里提到的"先跑 A/B 测 WER 再决定"的原则,而不是默认开。
- 没有做"DeepFilterNet3 模型自动下载"(类似 `ModelDownloader.swift` 那套 GUI 下载
  流程)——`fetch_deepfilter.sh` 是开发机构建脚本,不是给终端用户用的运行时下载器,
  这块超出本次任务范围。

## 测试

`test/test_denoise.sh`:
1. `--print-config` 验证 `denoise`/`remoteAsr` 默认值、部分覆盖 JSON 合并正确。
2. `--selftest-highpass`:合成 30Hz/1000Hz 纯音验证 `HighPassFilter` 实际频响
   (30Hz 衰减 >15dB,1000Hz 衰减 <1dB),不依赖任何模型/音频文件。
3. `--selftest-denoise-guard`:`deepFilterNet.modelPath` 指向不存在的文件时,验证
   `AudioPreprocessor` 优雅降级(退化为仅高通)而不是崩溃。

真实 DeepFilterNet3 模型 + `libdeepfilter.dylib` 的端到端效果(实际噪声场景下 WER
变化)需要先跑 `./fetch_deepfilter.sh`(需要 Rust 工具链),不在自动化测试范围内,
按 `docs/0003` 的建议做法是拿真实录音单独 A/B 测。

开发过程中额外跑过一次真实链路验证(不在 CI 里,因为要拉 Rust 工具链编译+下载
~8MB 模型):`fetch_deepfilter.sh` 实际编译产出确认 `df_get_frame_length() == 480`
(48kHz 下 10ms 帧长,和 DeepFilterNet 论文里的配置一致),`--selftest-denoise-real`
喂一段人工合成的"纯音+白噪声"混合信号,`df_process_frame` 真实跑通,输出 RMS 从
0.39 降到 0.043——确认整条链路(cargo-c 编译 → cbindgen 头文件 → Swift FFI → 帧缓冲)
是打通的,不只是"模型缺失时不崩溃"这一条 fail-open 路径。过程中也发现并修了两个
实际问题(不是纸面设计):
1. `cargo-c` 默认不认仓库根目录的 `cbindgen.toml`(只在被构建的 crate 目录里找),
   不修的话生成的头文件是 C++ 风格(`#include <cstdint>` 等),Swift systemLibrary
   按 C 解析直接报头文件找不到——`fetch_deepfilter.sh` 现在会把 `cbindgen.toml`
   拷进 `libDF/` 再编译。
2. `cargo capi install --prefix /` 生成的 dylib 的 install name 被写死成绝对路径
   `/lib/libdeepfilter.0.5.dylib`,换台机器/换路径就找不到库——`fetch_deepfilter.sh`
   现在会用 `install_name_tool -id @rpath/libdeepfilter.dylib` 改成相对路径(和
   sherpa-onnx 预编译库的做法一致),并重新做 ad-hoc 签名。
