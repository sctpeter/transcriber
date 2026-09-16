import AVFoundation
import Foundation

/// 麦克风采集:AVAudioEngine inputNode,以设备原生格式打 tap(不做任何隐式转换),写 WAV。
final class MicCapture {
    private let engine = AVAudioEngine()
    private var writer: WavWriter?

    /// 实际采集格式的采样率(启动后有效),用于 UI 验证"系统层零隐式转换"
    private(set) var activeSampleRate: Double = 0

    var onLevel: ((Float) -> Void)?
    /// 每块采集音频(已深拷贝,可跨线程投递给 ASR 管线)
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0) // 设备原生格式,通常 48kHz
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranscriberError.noAudioDevice
        }
        activeSampleRate = format.sampleRate

        let writer = try WavWriter(url: url, format: format)
        self.writer = writer

        input.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.writer?.write(buffer)
            self.onLevel?(AudioLevel.normalizedLevel(of: buffer))
            // tap 的 buffer 回调返回后可能被引擎复用,深拷贝再投递
            if let onBuffer = self.onBuffer, let copy = buffer.deepCopy() {
                onBuffer(copy)
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        writer = nil
        onLevel?(0)
    }
}

enum TranscriberError: LocalizedError {
    case noAudioDevice
    case noDisplay
    case micPermissionDenied

    var errorDescription: String? {
        switch self {
        case .noAudioDevice: return "未找到可用的音频输入设备"
        case .noDisplay: return "未找到可捕获的显示器"
        case .micPermissionDenied: return "麦克风权限被拒绝,请在 系统设置 → 隐私与安全性 → 麦克风 中开启"
        }
    }
}
