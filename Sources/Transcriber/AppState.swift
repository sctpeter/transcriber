import AVFoundation
import Foundation
import SwiftUI

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// final 精修实际在用的后端——不是"配置成了什么",是"这一刻真的在用哪个"。
/// 配置了远程但掉线回退本地时是 `.remoteFallback`,不是 `.local`(见 ContentView 的
/// 状态指示,这是用户明确要求的:不管配置是什么,始终显示真实当前后端)。
enum AsrBackendStatus: Equatable {
    case local
    case remoteConnected
    case remoteFallback

    var label: String {
        switch self {
        case .local: return "本地模型"
        case .remoteConnected: return "远程 Qwen3-ASR"
        case .remoteFallback: return "远程离线 · 已回退本地"
        }
    }

    var systemImage: String {
        switch self {
        case .local: return "desktopcomputer"
        case .remoteConnected: return "network"
        case .remoteFallback: return "network.slash"
        }
    }

    var color: Color {
        switch self {
        case .local: return .blue
        case .remoteConnected: return .green
        case .remoteFallback: return .orange
        }
    }
}

/// 采集会话的全局状态。阶段 3:采集 → 显式重采样 → VAD → 两遍 ASR → partial/final 上屏。
@MainActor
final class AppState: ObservableObject {
    // 输入源开关(计划 §2.3:仅麦克风 / 仅系统音频 / 双路)
    @Published var micEnabled = true
    @Published var sysEnabled = false

    @Published var isRecording = false
    @Published var isPreparing = false  // 模型加载中
    @Published var micLevel: Float = 0
    @Published var sysLevel: Float = 0
    @Published var micActive = false
    @Published var sysActive = false
    @Published var micSampleRate: Double = 0
    @Published var sysSampleRate: Double = 0
    @Published var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var lastSessionFolder: URL?

    // 转写文本:final 固化累积,partial 当前句可变(计划 §4.2 事件模型)
    @Published var micFinals: [TranscriptLine] = []
    @Published var micPartial = ""
    @Published var sysFinals: [TranscriptLine] = []
    @Published var sysPartial = ""
    /// ASR 不可用(模型缺失等)时降级为纯录音,原因显示在 UI
    @Published var asrUnavailableReason: String?
    /// 当前 final 精修实际在用的后端,实时反映真实状态(不是配置意图),见 ContentView
    @Published var asrBackendStatus: AsrBackendStatus = .local

    private let micCapture = MicCapture()
    private let sysCapture = SystemAudioCapture()
    private var refiner: SegmentRefiner?
    private var micPipeline: AsrPipeline?
    private var sysPipeline: AsrPipeline?
    private var micTranscript: TranscriptWriter?
    private var sysTranscript: TranscriptWriter?
    private var timer: Timer?
    private var startedAt: Date?
    private var lastMicLevelUpdate = Date.distantPast
    private var lastSysLevelUpdate = Date.distantPast

    /// 录音根目录:默认 ~/Documents/Transcriber/,可在设置里覆盖(config.json paths.recordingsRoot)
    nonisolated static var recordingsRoot: URL {
        if let override = ConfigStore.load().paths.recordingsRoot, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
    }

    init() {
        // 电平回调来自音频线程,节流后回主线程发布(UI 刷新 ~10Hz 足够)
        micCapture.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(self.lastMicLevelUpdate) > 0.08 else { return }
                self.lastMicLevelUpdate = Date()
                self.micLevel = level
            }
        }
        sysCapture.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(self.lastSysLevelUpdate) > 0.08 else { return }
                self.lastSysLevelUpdate = Date()
                self.sysLevel = level
            }
        }
        sysCapture.onStreamError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.errorMessage = "系统音频流中断:\(error.localizedDescription)"
                self.sysActive = false
                if !self.micActive { await self.stopRecording() }
            }
        }
    }

    func startRecording() async {
        guard !isRecording, !isPreparing else { return }
        errorMessage = nil
        asrUnavailableReason = nil
        guard micEnabled || sysEnabled else {
            errorMessage = "请至少开启一个输入源"
            return
        }

        let folder: URL
        do {
            folder = try makeSessionFolder()
        } catch {
            errorMessage = "无法创建录音目录:\(error.localizedDescription)"
            return
        }

        // 1) 加载 ASR 模型(~1.3GB int8 双模型,几秒;失败则降级为纯录音)
        isPreparing = true
        micFinals = []
        sysFinals = []
        micPartial = ""
        sysPartial = ""

        let wantMic = micEnabled
        let wantSys = sysEnabled
        // 每次开始转写重新读一次盘:设置面板的改动"下次开始转写"即生效
        let config = ConfigStore.load()
        let loaded: Result<(SegmentRefiner, AsrPipeline?, AsrPipeline?), Error> =
            await Task.detached(priority: .userInitiated) {
                do {
                    NSLog("AppState[DEBUG]: 开始 AsrModels.locate")
                    let models = try AsrModels.locate(config: config)
                    NSLog("AppState[DEBUG]: models 加载成功,remoteAsr.enabled=\(config.remoteAsr.enabled)")
                    let localRefiner = OfflineRefiner(models: models, config: config)
                    // 远程 Qwen3-ASR 精修final时,本地 paraformer-large 仍然常驻,
                    // 只是降级为"远程不可用/超时"时的兜底(见 RemoteAsrRefiner)。
                    let refiner: SegmentRefiner =
                        config.remoteAsr.enabled
                        ? RemoteAsrRefiner(config: config.remoteAsr, localFallback: localRefiner)
                        : localRefiner
                    NSLog("AppState[DEBUG]: refiner 构造完成,类型=\(type(of: refiner))")
                    let mic = wantMic
                        ? AsrPipeline(label: "mic", models: models, refiner: refiner, config: config)
                        : nil
                    let sys = wantSys
                        ? AsrPipeline(label: "sys", models: models, refiner: refiner, config: config)
                        : nil
                    return .success((refiner, mic, sys))
                } catch {
                    return .failure(error)
                }
            }.value
        isPreparing = false

        switch loaded {
        case .success(let (refiner, mic, sys)):
            self.refiner = refiner
            self.micPipeline = mic
            self.sysPipeline = sys
            if let remote = refiner as? RemoteAsrRefiner {
                asrBackendStatus = .remoteFallback  // 还没连上前的真实状态,不是"本地"
                remote.onConnectionChange = { [weak self] connected in
                    self?.asrBackendStatus = connected ? .remoteConnected : .remoteFallback
                }
            } else {
                asrBackendStatus = .local
            }
            if let mic {
                micTranscript = TranscriptWriter(
                    url: folder.appendingPathComponent("transcript_mic.txt"))
                bind(pipeline: mic, isMic: true)
            }
            if let sys {
                sysTranscript = TranscriptWriter(
                    url: folder.appendingPathComponent("transcript_system.txt"))
                bind(pipeline: sys, isMic: false)
            }
        case .failure(let error):
            asrUnavailableReason = "ASR 不可用,本次仅录音:\(error.localizedDescription)"
        }

        // 2) 启动采集
        var failures: [String] = []

        if micEnabled {
            if await MicCapture.requestPermission() {
                do {
                    micCapture.onBuffer = { [weak self] buffer in
                        self?.micPipeline?.process(buffer)
                    }
                    try micCapture.start(writingTo: folder.appendingPathComponent("mic.wav"))
                    micActive = true
                    micSampleRate = micCapture.activeSampleRate
                } catch {
                    failures.append("麦克风启动失败:\(error.localizedDescription)")
                }
            } else {
                failures.append(TranscriberError.micPermissionDenied.localizedDescription)
            }
        }

        if sysEnabled {
            do {
                sysCapture.onBuffer = { [weak self] buffer in
                    self?.sysPipeline?.process(buffer)
                }
                try await sysCapture.start(writingTo: folder.appendingPathComponent("system.wav"))
                sysActive = true
            } catch {
                failures.append(
                    "系统音频启动失败(需要在 系统设置 → 隐私与安全性 → 屏幕录制 中授权):\(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }

        guard micActive || sysActive else {
            try? FileManager.default.removeItem(at: folder)
            releasePipelines()
            return
        }

        lastSessionFolder = folder
        isRecording = true
        startedAt = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                // 系统音频实际格式在首个 buffer 后才可知,轮询补上
                if self.sysActive, self.sysSampleRate == 0 {
                    self.sysSampleRate = self.sysCapture.activeSampleRate
                }
            }
        }
    }

    func stopRecording() async {
        guard isRecording || micActive || sysActive else { return }
        timer?.invalidate()
        timer = nil
        startedAt = nil
        // 先停采集(不再有新 buffer),再冲刷管线
        if micActive { micCapture.stop() }
        if sysActive { await sysCapture.stop() }
        micActive = false
        sysActive = false
        micLevel = 0
        sysLevel = 0
        micSampleRate = 0
        sysSampleRate = 0
        isRecording = false

        let mic = micPipeline
        let sys = sysPipeline
        let ref = refiner
        if mic != nil || sys != nil {
            await Task.detached(priority: .userInitiated) {
                mic?.finish()
                sys?.finish()
                ref?.waitUntilDrained()
            }.value
            // final 已实时逐句落盘;主队列 FIFO 保证最后几句 append 完再关文件
            DispatchQueue.main.async { [weak self] in
                self?.releasePipelines()  // 关转写文件,释放 ~1.3GB 模型内存
            }
        }
    }

    func revealRecordings() {
        let target = lastSessionFolder ?? Self.recordingsRoot
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - private

    /// 管线回调 → 主队列发布。用 DispatchQueue.main(FIFO)而非 Task,
    /// 保证 stop 时"先 final 后落盘"的顺序。
    private func bind(pipeline: AsrPipeline, isMic: Bool) {
        pipeline.engine.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                if isMic { self?.micPartial = text } else { self?.sysPartial = text }
            }
        }
        pipeline.engine.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                if isMic {
                    self.micFinals.append(TranscriptLine(text: text))
                    self.micTranscript?.append(text)  // 句到即落盘
                } else {
                    self.sysFinals.append(TranscriptLine(text: text))
                    self.sysTranscript?.append(text)
                }
            }
        }
    }

    private func releasePipelines() {
        micTranscript?.close()
        sysTranscript?.close()
        micTranscript = nil
        sysTranscript = nil
        micPipeline = nil
        sysPipeline = nil
        refiner = nil
        micCapture.onBuffer = nil
        sysCapture.onBuffer = nil
        asrBackendStatus = .local  // 没有会话在跑,不该显示上一次的远程/回退状态
    }

    private func makeSessionFolder() throws -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let folder = Self.recordingsRoot.appendingPathComponent(
            fmt.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
