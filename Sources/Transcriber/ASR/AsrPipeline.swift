import AVFoundation
import Foundation

/// 单个输入源的完整转写管线:
///   采集 buffer(任意格式)→ [AudioPreprocessor:高通/DeepFilterNet3,原生率,可选]
///     → StreamingResampler(显式 48k→16k)→ AsrEngine(VAD+两遍)
///
/// 持有串行队列,采集回调只做投递,重活全部离开音频线程。
final class AsrPipeline {
    let engine: AsrEngine
    private var resampler: StreamingResampler?
    private var preprocessor: AudioPreprocessor?
    private var preprocessorInitialized = false
    private let config: TranscriberConfig
    private let queue: DispatchQueue

    init(
        label: String, models: AsrModels, refiner: SegmentRefiner,
        config: TranscriberConfig = ConfigStore.load()
    ) {
        engine = AsrEngine(models: models, refiner: refiner, config: config)
        self.config = config
        queue = DispatchQueue(label: "transcriber.pipeline.\(label)", qos: .userInitiated)
    }

    /// 采集线程调用。buffer 必须已深拷贝(或本来就是独立分配的)。
    func process(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            if !preprocessorInitialized {
                preprocessorInitialized = true
                preprocessor = AudioPreprocessor(inputFormat: buffer.format, config: config)
            }
            let preprocessed = preprocessor?.process(buffer) ?? buffer

            if resampler == nil {
                resampler = StreamingResampler(inputFormat: preprocessed.format)
                if resampler == nil {
                    NSLog("AsrPipeline: 无法为格式 \(preprocessed.format) 创建重采样器")
                    return
                }
            }
            let samples = resampler?.process(preprocessed) ?? []
            engine.feed(samples)
        }
    }

    /// 停止:冲刷 VAD 尾段并等待队列排空
    func finish() {
        queue.sync { engine.finish() }
    }
}
