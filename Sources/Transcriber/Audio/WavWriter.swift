import AVFoundation
import Foundation

/// 把 PCM buffer 顺序写入 16-bit WAV 文件。
/// 只做位深转换(float32 → int16),不改采样率、不改声道数——
/// 采样率转换必须显式发生在链路的重采样层(阶段 3),这里绝不隐式转换。
final class WavWriter {
    let url: URL
    let sampleRate: Double
    let channelCount: UInt32

    private var file: AVAudioFile?
    private let lock = NSLock()

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        self.sampleRate = format.sampleRate
        self.channelCount = format.channelCount
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // 处理格式与写入 buffer 的格式保持一致,AVAudioFile 内部完成到文件格式的位深转换
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try file?.write(from: buffer)
        } catch {
            NSLog("WavWriter write error: \(error)")
        }
    }

    /// 关闭文件(置 nil 触发 AVAudioFile 落盘)
    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }
}

enum AudioLevel {
    /// 计算 buffer 的 RMS 并映射到 0...1(-60dB → 0, 0dB → 1),用于 UI 电平表
    static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            let samples = data[ch]
            for i in 0..<n { sum += samples[i] * samples[i] }
        }
        let rms = sqrt(sum / Float(n * Int(buffer.format.channelCount)))
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 60))
    }
}
