import AVFoundation
import Foundation

/// 无头自测:`Transcriber --selftest <wav> [--realtime]`
///
/// 把 wav 按 100ms 一块模拟实时喂入完整管线(重采样→VAD→流式 partial→离线 final),
/// 打印 partial/final 与吞吐统计。验证 ASR 栈时不需要真开麦克风。
enum SelfTest {
    static func run(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--selftest"), arguments.count > i + 1 else {
            fputs("用法: Transcriber --selftest <wav文件> [--realtime]\n", stderr)
            exit(2)
        }
        let wavPath = arguments[i + 1]
        let realtime = arguments.contains("--realtime")

        do {
            try runPipeline(wavPath: wavPath, realtime: realtime)
        } catch {
            fputs("selftest 失败: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    private static func runPipeline(wavPath: String, realtime: Bool) throws {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
        let format = file.processingFormat
        let totalSeconds = Double(file.length) / format.sampleRate
        print("输入: \(wavPath)")
        print(String(format: "格式: %.0f Hz, %d ch, 时长 %.1fs", format.sampleRate,
                     format.channelCount, totalSeconds))

        let models = try AsrModels.locate()
        print("模型目录: \(models.vadModel.deletingLastPathComponent().path)")

        let loadStart = Date()
        let refiner = OfflineRefiner(models: models)
        let pipeline = AsrPipeline(label: "selftest", models: models, refiner: refiner)
        print(String(format: "模型加载: %.1fs", Date().timeIntervalSince(loadStart)))

        // partial 打印到同一行(\r 刷新),final 换行固化
        pipeline.engine.onPartial = { text in
            guard !text.isEmpty else { return }
            let display = text.count > 76 ? "…" + text.suffix(75) : text
            print("\r\u{1B}[2K  ⋯ \(display)", terminator: "")
            fflush(stdout)
        }
        pipeline.engine.onFinal = { text in
            print("\r\u{1B}[2K✔ \(text)")
            fflush(stdout)
        }

        // 100ms 一块模拟实时
        let chunkFrames = AVAudioFrameCount(format.sampleRate / 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NSError(domain: "selftest", code: 1)
        }

        let feedStart = Date()
        while true {
            if file.framePosition >= file.length { break }
            do {
                try file.read(into: buffer, frameCount: chunkFrames)
            } catch {
                fputs("read 失败 @frame \(file.framePosition)/\(file.length): \(error)\n", stderr)
                throw error
            }
            if buffer.frameLength == 0 { break }
            guard let copy = buffer.deepCopy() else { break }
            pipeline.process(copy)
            if realtime {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        pipeline.finish()
        refiner.waitUntilDrained()

        let wall = Date().timeIntervalSince(feedStart)
        print(String(format: "\n音频 %.1fs,处理墙钟 %.1fs,RTF %.3f",
                     totalSeconds, wall, wall / totalSeconds))
    }

    /// `Transcriber --selftest-highpass`:合成 30Hz(应大幅衰减)和 1000Hz(应基本无损通过)
    /// 两路纯音,验证 HighPassFilter 的实际频响,不依赖任何模型/音频文件。
    static func runHighPassCheck() -> Never {
        let sampleRate = 48000.0
        let n = Int(sampleRate)  // 1 秒

        func attenuationDb(freqHz: Double) -> Float {
            var signal = [Float](repeating: 0, count: n)
            for i in 0..<n {
                signal[i] = Float(sin(2 * Double.pi * freqHz * Double(i) / sampleRate))
            }
            var output = signal
            let filter = HighPassFilter(cutoffHz: 80, sampleRate: sampleRate)
            filter.process(&output)
            // 跳过前 5% 让滤波器状态稳定下来,避免瞬态影响 RMS
            let skip = n / 20
            func rms(_ xs: ArraySlice<Float>) -> Float {
                sqrt(xs.reduce(Float(0)) { $0 + $1 * $1 } / Float(xs.count))
            }
            let inRms = rms(signal[skip...])
            let outRms = rms(output[skip...])
            return 20 * log10(outRms / inRms)
        }

        let lowAtten = attenuationDb(freqHz: 30)
        let highAtten = attenuationDb(freqHz: 1000)
        print(String(format: "30Hz 衰减: %.1f dB (期望 < -15dB)", lowAtten))
        print(String(format: "1000Hz 衰减: %.1f dB (期望 > -1dB,基本无损)", highAtten))
        exit(lowAtten < -15 && highAtten > -1 ? 0 : 1)
    }

    /// `Transcriber --selftest-denoise-guard`:DeepFilterNet3 模型路径指向不存在的文件时,
    /// AudioPreprocessor 必须优雅降级(跳过 DF3、保留高通),不能让整条录音管线崩掉。
    static func runDenoiseGuardCheck() -> Never {
        var config = TranscriberConfig()
        config.denoise.highPass.enabled = true
        config.denoise.deepFilterNet.enabled = true
        config.denoise.deepFilterNet.modelPath = "/nonexistent/DeepFilterNet3_onnx.tar.gz"

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1,
                interleaved: false)
        else {
            fputs("无法创建测试用 AVAudioFormat\n", stderr)
            exit(1)
        }
        guard let preprocessor = AudioPreprocessor(inputFormat: format, config: config) else {
            print("❌ 只要有一个开关打开,AudioPreprocessor 就不该返回 nil")
            exit(1)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) else {
            exit(1)
        }
        buffer.frameLength = 4800
        if let ch = buffer.floatChannelData {
            for i in 0..<4800 {
                ch[0][i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48000))
            }
        }
        let output = preprocessor.process(buffer)
        print("模型缺失时仍正常处理(降级为仅高通),输出帧数: \(output.frameLength)")
        exit(output.frameLength == 4800 ? 0 : 1)
    }

    /// `Transcriber --selftest-denoise-real <DeepFilterNet3_onnx.tar.gz>`:用真实模型跑几帧
    /// 48kHz 白噪声+纯音混合信号,验证 df_create/df_process_frame 真的能跑通(不是只测
    /// "模型缺失时不崩溃"那条 fail-open 路径)。不在 test_denoise.sh 的默认流程里,因为
    /// 需要先跑 fetch_deepfilter.sh 编译出 libdeepfilter 并准备好模型文件。
    static func runDenoiseRealCheck(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--selftest-denoise-real"),
            arguments.count > i + 1
        else {
            fputs("用法: Transcriber --selftest-denoise-real <DeepFilterNet3_onnx.tar.gz>\n", stderr)
            exit(2)
        }
        let modelPath = URL(fileURLWithPath: arguments[i + 1])
        guard let denoiser = DeepFilterNetDenoiser(modelPath: modelPath, attenLimitDb: 30) else {
            print("❌ df_create 失败,模型路径: \(modelPath.path)")
            exit(1)
        }
        print("frameLength = \(denoiser.frameLength)")

        var rng = SystemRandomNumberGenerator()
        let totalSamples = denoiser.frameLength * 20
        var input = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            let tone = sin(2 * Double.pi * 200 * Double(i) / 48000)
            let noise = Double.random(in: -0.3...0.3, using: &rng)
            input[i] = Float(tone * 0.5 + noise)
        }
        let output = denoiser.process(input)
        func rms(_ xs: [Float]) -> Float {
            guard !xs.isEmpty else { return 0 }
            return sqrt(xs.reduce(Float(0)) { $0 + $1 * $1 } / Float(xs.count))
        }
        print(String(format: "输入 RMS: %.4f,输出 RMS: %.4f,输出样本数: %d", rms(input), rms(output), output.count))
        exit(output.isEmpty ? 1 : 0)
    }

    /// 测试专用的哑 SegmentRefiner:不依赖真实 ASR 模型文件,固定返回一段文本,
    /// 用来在 `--selftest-remote-asr` 里区分"远程真的回结果了"还是"回退到本地了"。
    private final class FixedTextRefiner: SegmentRefiner {
        private let text: String
        init(text: String) { self.text = text }
        func refine(samples: [Float], completion: @escaping (String) -> Void) { completion(text) }
        func enqueueOrdered(_ block: @escaping () -> Void) { block() }
        func waitUntilDrained() {}
    }

    /// `Transcriber --selftest-remote-asr <serverURL> <p12Path> <p12Password> <caCertPath> <timeoutSeconds>`
    /// 连一次远程 ASR 网关(或 test/remote_asr_mock_server.py),发一段假音频,打印收到
    /// 的文本——是 mock 服务器返回的 "mock-transcript-ok" 还是本地兜底的
    /// "LOCAL_FALLBACK_TEXT",由调用方(test_remote_asr.sh)据此判断 mTLS 握手/协议/
    /// fail-open 是否符合预期,不做真实语音识别准确率验证。
    static func runRemoteAsrCheck(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--selftest-remote-asr"),
            arguments.count > i + 5
        else {
            fputs(
                "用法: Transcriber --selftest-remote-asr <serverURL> <p12Path> <p12Password> <caCertPath> <timeoutSeconds>\n",
                stderr)
            exit(2)
        }
        var config = TranscriberConfig.RemoteAsr()
        config.enabled = true
        config.serverURL = arguments[i + 1]
        config.clientIdentityPath = arguments[i + 2]
        config.clientIdentityPassword = arguments[i + 3]
        config.caCertPath = arguments[i + 4]
        config.timeoutSeconds = Float(arguments[i + 5]) ?? 5

        let fallback = FixedTextRefiner(text: "LOCAL_FALLBACK_TEXT")
        let remote = RemoteAsrRefiner(config: config, localFallback: fallback)

        // 给 mTLS 握手/建连留点时间,再发真正的测试段落
        Thread.sleep(forTimeInterval: 1.0)

        let semaphore = DispatchSemaphore(value: 0)
        var received = "<no-callback>"
        let samples = [Float](repeating: 0, count: 1600)
        remote.refine(samples: samples) { text in
            received = text
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + Double(config.timeoutSeconds) + 3)
        if waitResult == .timedOut {
            print("❌ 超过预期时间都没有触发 completion(应该最迟在 timeoutSeconds 后回退本地)")
            exit(1)
        }
        print(received)
        exit(0)
    }
}
