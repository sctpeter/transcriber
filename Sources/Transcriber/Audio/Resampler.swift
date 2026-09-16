import AVFoundation
import Foundation

/// 链路中唯一一次采样率转换:任意输入格式 → 16kHz 单声道 float32。
///
/// 计划 §三:系统层零隐式转换,显式重采样在自己代码里完成。
/// 用 AVAudioConverter 流式模式(带内部滤波器状态,跨 chunk 连续,
/// 不会出现"拆小块后滤波器状态断裂"的问题——见学习笔记对 ffmpeg 分块的分析),
/// 质量设为最高(mastering 算法,内部为带抗混叠低通的多相滤波)。
final class StreamingResampler {
    static let targetRate: Double = 16000

    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private let ratio: Double

    init?(inputFormat: AVAudioFormat) {
        guard
            let out = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetRate,
                channels: 1,
                interleaved: false),
            let conv = AVAudioConverter(from: inputFormat, to: out)
        else { return nil }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        outFormat = out
        converter = conv
        ratio = Self.targetRate / inputFormat.sampleRate
    }

    /// 送入一块任意长度的输入 buffer,返回对应的 16k 采样(长度可能与理论值差几帧,滤波器延迟所致)
    func process(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            return []
        }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let ch = out.floatChannelData, out.frameLength > 0 else {
            if let convError { NSLog("Resampler error: \(convError)") }
            return []
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

extension AVAudioPCMBuffer {
    /// 深拷贝。AVAudioEngine tap 的 buffer 在回调返回后可能被复用,
    /// 跨线程投递前必须复制。
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let srcBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList))
        let dstBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(srcBuffers.count, dstBuffers.count) {
            if let s = srcBuffers[i].mData, let d = dstBuffers[i].mData {
                memcpy(d, s, Int(srcBuffers[i].mDataByteSize))
            }
        }
        return copy
    }
}
