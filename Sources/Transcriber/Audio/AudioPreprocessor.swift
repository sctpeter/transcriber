import AVFoundation
import Foundation

/// 在重采样之前、原生采样率下做的可选降噪预处理:
///
///   采集 buffer(原生格式,任意声道数)→ 下混单声道 → [高通] → [DeepFilterNet3] → 单声道原生率 buffer
///       → 交给 StreamingResampler(照常显式重采样到 16k)
///
/// 两个开关默认都关闭,行为与改造前完全一致(见 docs/0002)。DeepFilterNet3 必须插在
/// 重采样之前:它的模型固定按 48kHz 训练/导出,在 16k 上跑输入采样率对不上。
/// 任一环节初始化失败都是 fail-open(跳过该环节,不阻断录音),不会让整条管线崩掉。
final class AudioPreprocessor {
    private let highPass: HighPassFilter?
    private let denoiser: DeepFilterNetDenoiser?
    private let monoFormat: AVAudioFormat

    /// 返回 nil 表示两个开关都没开,调用方应完全跳过这一层(零开销)
    init?(inputFormat: AVAudioFormat, config: TranscriberConfig) {
        let denoiseConfig = config.denoise
        guard denoiseConfig.highPass.enabled || denoiseConfig.deepFilterNet.enabled else {
            return nil
        }
        guard
            let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                channels: 1, interleaved: false)
        else { return nil }
        monoFormat = mono

        highPass =
            denoiseConfig.highPass.enabled
            ? HighPassFilter(
                cutoffHz: denoiseConfig.highPass.cutoffHz, sampleRate: inputFormat.sampleRate)
            : nil

        var resolvedDenoiser: DeepFilterNetDenoiser?
        if denoiseConfig.deepFilterNet.enabled {
            if inputFormat.sampleRate != 48000 {
                NSLog(
                    "AudioPreprocessor: DeepFilterNet3 要求原生采样率为 48kHz,当前是 "
                        + "\(inputFormat.sampleRate)Hz,本次会话跳过降噪")
            } else if let modelURL = Self.locateModel(config: config) {
                resolvedDenoiser = DeepFilterNetDenoiser(
                    modelPath: modelURL, attenLimitDb: denoiseConfig.deepFilterNet.attenLimitDb)
            } else {
                NSLog("AudioPreprocessor: 未找到 DeepFilterNet3 模型文件(见设置里的模型路径),本次会话跳过降噪")
            }
        }
        denoiser = resolvedDenoiser
    }

    /// 采集线程/管线队列上调用。输入可以是任意声道数,输出恒为单声道、同原生采样率。
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        var samples = downmix(buffer)
        highPass?.process(&samples)
        if let denoiser {
            samples = denoiser.process(samples)
        }
        return wrap(samples)
    }

    /// 模型文件查找:复用 ASR 模型的搜索目录(TRANSCRIBER_MODELS → config.paths.modelsDir
    /// → App Support/Transcriber/models),文件名固定 DeepFilterNet3_onnx.tar.gz;
    /// 设置面板里手填的 modelPath 优先级最高。
    private static func locateModel(config: TranscriberConfig) -> URL? {
        if let override = config.denoise.deepFilterNet.modelPath, !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        for root in AsrModels.searchPaths(config: config) {
            let candidate = root.appendingPathComponent("DeepFilterNet3_onnx.tar.gz")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0 else { return [] }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for ch in 0..<channelCount {
            let chPtr = channels[ch]
            for i in 0..<frameCount { mono[i] += chPtr[i] }
        }
        let scale = 1 / Float(channelCount)
        for i in 0..<frameCount { mono[i] *= scale }
        return mono
    }

    private func wrap(_ samples: [Float]) -> AVAudioPCMBuffer {
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let dst = buffer.floatChannelData
        else {
            return AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 0)!
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            dst[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
