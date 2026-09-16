import AVFoundation
import Foundation
import ScreenCaptureKit

/// 系统音频采集:ScreenCaptureKit,SCStreamConfiguration 显式指定 48kHz 输出,
/// 无需虚拟声卡;首次使用触发"屏幕录制"授权。
final class SystemAudioCapture: NSObject {
    private var stream: SCStream?
    private var writer: WavWriter?
    private var pendingURL: URL?
    private let sampleQueue = DispatchQueue(label: "transcriber.sysaudio")

    private(set) var activeSampleRate: Double = 0

    var onLevel: ((Float) -> Void)?
    var onStreamError: ((Error) -> Void)?
    /// 每块采集音频(独立分配的 buffer,可直接跨线程投递)
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(writingTo url: URL) async throws {
        // 触发屏幕录制 TCC;未授权时此调用抛错
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw TranscriberError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000 // 显式指定,系统层不做隐式转换(计划 §三)
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        // 只要音频:视频流压到最低成本(不添加视频 output)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        pendingURL = url
        writer = nil
        activeSampleRate = 0

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        sampleQueue.sync { [weak self] in
            self?.writer?.close()
            self?.writer = nil
        }
        onLevel?(0)
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid,
            let pcm = sampleBuffer.toPCMBuffer()
        else { return }

        // 首个 buffer 到达时才知道实际格式,据此建 writer
        if writer == nil, let url = pendingURL {
            writer = try? WavWriter(url: url, format: pcm.format)
            activeSampleRate = pcm.format.sampleRate
            pendingURL = nil
        }
        writer?.write(pcm)
        onLevel?(AudioLevel.normalizedLevel(of: pcm))
        onBuffer?(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }
}

extension CMSampleBuffer {
    /// CMSampleBuffer(音频)→ AVAudioPCMBuffer,零拷贝语义不保证,但格式原样保留
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let fd = formatDescription,
            var asbd = fd.audioStreamBasicDescription,
            let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0,
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
