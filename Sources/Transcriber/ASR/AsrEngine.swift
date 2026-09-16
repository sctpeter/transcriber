import Foundation

/// 两遍识别引擎(计划 §4.1/§4.6):
///
///   16k PCM ─→ Silero VAD ──静音切除+分段──→ 流式 Paraformer → partial(灰色,可变)
///                     └─ 段落闭合(≥0.8s 静音)→ 离线 paraformer-large 精修 → final(固化)
///
/// 每个输入源一个实例。所有 sherpa 调用都在调用方保证的串行队列上执行
/// (AsrPipeline 持有队列),内部不再加锁。
final class AsrEngine {
    /// partial 文本更新(当前句,可被后续修正)
    var onPartial: ((String) -> Void)?
    /// final 文本(整句固化,精修后)
    var onFinal: ((String) -> Void)?

    private let vad: SherpaOnnxVoiceActivityDetectorWrapper
    private let online: SherpaOnnxRecognizer
    private let refiner: SegmentRefiner

    /// VAD 判定说话前的 pre-roll:Silero 触发有 ~100-200ms 延迟,
    /// 环形保留最近 0.5s,speech 起始时先喂进流式识别器,避免吞掉句首。
    private var preRoll: [Float] = []
    private let preRollCapacity = 8000  // 0.5s @ 16k

    private var inSpeech = false
    private var lastPartial = ""

    init(models: AsrModels, refiner: SegmentRefiner, config: TranscriberConfig = ConfigStore.load()) {
        self.refiner = refiner

        // VAD:静音时长/阈值等可调(计划 §五),默认 800ms 静音 = endpoint,最长 28s 强切防止无停顿长段
        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: models.vadModel.path,
                threshold: config.vad.threshold,
                minSilenceDuration: config.vad.minSilenceDuration,
                minSpeechDuration: config.vad.minSpeechDuration,
                windowSize: config.vad.windowSize,
                maxSpeechDuration: config.vad.maxSpeechDuration
            ),
            sampleRate: 16000,
            numThreads: 1
        )
        vad = SherpaOnnxVoiceActivityDetectorWrapper(
            config: &vadConfig, buffer_size_in_seconds: 60)

        // 流式双语 Paraformer(§4.6 实测:英文术语正确,RTF 0.036)
        var onlineConfig = sherpaOnnxOnlineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: sherpaOnnxOnlineModelConfig(
                tokens: models.streamingTokens.path,
                paraformer: sherpaOnnxOnlineParaformerModelConfig(
                    encoder: models.streamingEncoder.path,
                    decoder: models.streamingDecoder.path
                ),
                // ⚠️ modelType 必须留空:显式设 "paraformer" 会跳过模型元数据读取,
                // encoder 状态初始化不完整,ORT 在 Split 节点报
                // "GetElementType is not implemented"(2026-07-02 实测)
                numThreads: config.asr.numThreads,
                provider: config.asr.provider
            ),
            enableEndpoint: false,  // endpoint 由 VAD 负责
            decodingMethod: "greedy_search"  // paraformer 仅支持 greedy_search,见 docs/0007
        )
        online = SherpaOnnxRecognizer(config: &onlineConfig)
    }

    /// 喂入 16k 单声道 float 采样(串行队列上调用)
    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        vad.acceptWaveform(samples: samples)

        let speaking = vad.isSpeechDetected()
        if speaking {
            if !inSpeech {
                inSpeech = true
                // 句首补 pre-roll
                if !preRoll.isEmpty {
                    online.acceptWaveform(samples: preRoll, sampleRate: 16000)
                }
            }
            online.acceptWaveform(samples: samples, sampleRate: 16000)
            while online.isReady() { online.decode() }
            let text = online.getResult().text
            if text != lastPartial {
                lastPartial = text
                onPartial?(text)
            }
        }

        // 维护 pre-roll 环形缓存(仅静音期需要,说话期已实时喂入)
        preRoll.append(contentsOf: samples)
        if preRoll.count > preRollCapacity {
            preRoll.removeFirst(preRoll.count - preRollCapacity)
        }

        drainSegments()
    }

    /// selftest / 停止录制时冲刷:把 VAD 内部缓存的尾段吐出来
    func finish() {
        vad.flush()
        drainSegments()
        // 尾段之后可能还有未闭合的 partial,作为 final 兜底
        if inSpeech, !lastPartial.isEmpty {
            emitFinal(fallback: lastPartial, samples: nil)
            resetUtterance()
        }
    }

    /// VAD 吐出的完整语音段 → 离线精修 → final
    private func drainSegments() {
        while !vad.isEmpty() {
            let segment = vad.front()
            let samples = segment.samples
            vad.pop()
            emitFinal(fallback: lastPartial, samples: samples)
            resetUtterance()
        }
    }

    private func emitFinal(fallback: String, samples: [Float]?) {
        if let samples, !samples.isEmpty {
            refiner.refine(samples: samples) { [weak self] refined in
                let text = refined.isEmpty ? fallback : refined
                guard !text.isEmpty else { return }
                self?.onFinal?(text)
            }
        } else if !fallback.isEmpty {
            refiner.enqueueOrdered { [weak self] in
                self?.onFinal?(fallback)
            }
        }
    }

    private func resetUtterance() {
        online.reset()
        lastPartial = ""
        inSpeech = false
        preRoll.removeAll(keepingCapacity: true)
        onPartial?("")
    }
}

/// 精修一段 VAD 已闭合的完整语音段、产出 final 文本的抽象。
/// 本地 `OfflineRefiner`(paraformer-large)和远程 `RemoteAsrRefiner`(Qwen3-ASR,
/// 见 ASR/RemoteAsrRefiner.swift)都实现这个协议,`AsrEngine` 不关心具体是哪一种。
protocol SegmentRefiner: AnyObject {
    /// 对一段完整语音精修,按句序调用 completion(不保证在哪个线程)
    func refine(samples: [Float], completion: @escaping (String) -> Void)
    /// 无音频可精修时的兜底(见 AsrEngine.finish()),仍需保持与 refine 的相对顺序
    func enqueueOrdered(_ block: @escaping () -> Void)
    /// 同步等待所有已提交的 refine/enqueueOrdered 任务完成(停止录制时用,见 AppState.stopRecording)
    func waitUntilDrained()
}

/// 离线 paraformer-large 精修器。全 App 共享一个实例(模型 ~750MB 常驻,§4.6),
/// 自带串行队列:天然保证同一引擎的 final 按句序回调,解码 RTF 0.013 不会积压。
final class OfflineRefiner: SegmentRefiner {
    private let recognizer: SherpaOnnxOfflineRecognizer
    private let queue = DispatchQueue(label: "transcriber.offline-refine", qos: .userInitiated)

    init(models: AsrModels, config: TranscriberConfig = ConfigStore.load()) {
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: models.offlineTokens.path,
                paraformer: sherpaOnnxOfflineParaformerModelConfig(
                    model: models.offlineModel.path
                ),
                numThreads: config.asr.numThreads,
                provider: config.asr.provider,
                modelType: "paraformer"
            ),
            decodingMethod: "greedy_search"  // paraformer 仅支持 greedy_search,见 docs/0007
        )
        recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
    }

    func refine(samples: [Float], completion: @escaping (String) -> Void) {
        queue.async { [self] in
            let result = recognizer.decode(samples: samples, sampleRate: 16000)
            completion(result.text)
        }
    }

    /// 无音频可精修时(兜底 final),仍走同一队列保持句序
    func enqueueOrdered(_ block: @escaping () -> Void) {
        queue.async { block() }
    }

    /// 同步等待队列排空(selftest 用)
    func waitUntilDrained() {
        queue.sync {}
    }
}
