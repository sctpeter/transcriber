import AppKit
import SwiftUI

/// 设置面板(Cmd+, 打开,或 ContentView 右上角的齿轮按钮)。
/// 编辑后点「保存」立即写入 config.json;对正在录制的会话不生效,
/// 下次点「开始转写」时才会用新值重建识别引擎。
struct SettingsView: View {
    @State private var config = ConfigStore.load()
    @State private var saveError: String?
    @State private var justSaved = false

    var body: some View {
        Form {
            Section("语音活动检测(VAD)") {
                LabeledSlider(
                    title: "灵敏度阈值", value: $config.vad.threshold, range: 0.1...0.9,
                    hint: "越低越容易判定为\"在说话\"")
                LabeledSlider(
                    title: "断句静音时长(秒)", value: $config.vad.minSilenceDuration, range: 0.2...3.0,
                    hint: "停顿多久算一句话说完")
                LabeledSlider(
                    title: "最短语音时长(秒)", value: $config.vad.minSpeechDuration, range: 0.05...1.0,
                    hint: "过滤掉比这更短的噪声")
                LabeledSlider(
                    title: "单句最长时长(秒)", value: $config.vad.maxSpeechDuration, range: 5...60,
                    hint: "说话不停顿时强制切分,防止段落无限增长")
                Picker("VAD 窗口大小", selection: $config.vad.windowSize) {
                    Text("256").tag(256)
                    Text("512(默认)").tag(512)
                }
                .pickerStyle(.segmented)
            }

            Section("本地识别性能（sherpa-onnx）") {
                Stepper("线程数:\(config.asr.numThreads)", value: $config.asr.numThreads, in: 1...8)
                Text("仅影响本地实时预览和本地 final 精修，不影响远程 Qwen3-ASR。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("推理后端:cpu(当前预编译库仅含 CPU);解码:greedy_search(paraformer 仅支持此项)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("降噪（默认关闭）") {
                Toggle("高通滤波", isOn: $config.denoise.highPass.enabled)
                if config.denoise.highPass.enabled {
                    LabeledSlider(
                        title: "截止频率(Hz)", value: $config.denoise.highPass.cutoffHz,
                        range: 40...200, hint: "压低桌面震动/电源哼声等低频底噪,默认 80Hz 基本不伤语音")
                }
                Divider()
                Toggle("DeepFilterNet3 深度降噪", isOn: $config.denoise.deepFilterNet.enabled)
                if config.denoise.deepFilterNet.enabled {
                    LabeledSlider(
                        title: "最大衰减(dB)", value: $config.denoise.deepFilterNet.attenLimitDb,
                        range: 6...100, hint: "越大降噪越强,过大容易引入 artifact、伤清辅音")
                    FilePathOverrideRow(
                        title: "模型文件(DeepFilterNet3_onnx.tar.gz)",
                        hint: "留空 = 到模型搜索目录里找同名文件(见 fetch_deepfilter.sh 输出)",
                        path: $config.denoise.deepFilterNet.modelPath
                    )
                    Text("仅在原生采样率为 48kHz 时生效,否则本次会话自动跳过(不阻断录音)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("远程 ASR（Qwen3-ASR，默认关闭）") {
                Toggle("精修(final)走远程 Qwen3-ASR", isOn: $config.remoteAsr.enabled)
                Text("partial 永远走本地流式模型,不受这个开关影响;远程不可用时自动回退本地精修")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if config.remoteAsr.enabled {
                    TextField("服务器地址", text: $config.remoteAsr.serverURL,
                        prompt: Text("wss://asr.internal.example.com:8765/v1/transcribe"))
                    FilePathOverrideRow(
                        title: "CA 根证书(必填,用来确认没连到别的服务器)",
                        hint: "certs/make_remote_asr_certs.sh init 生成的 certs/ca/ca.crt",
                        path: Binding(
                            get: { config.remoteAsr.caCertPath.isEmpty ? nil : config.remoteAsr.caCertPath },
                            set: { config.remoteAsr.caCertPath = $0 ?? "" })
                    )
                    LabeledSlider(
                        title: "单段超时(秒)", value: $config.remoteAsr.timeoutSeconds,
                        range: 2...30, hint: "超时自动回退本地 paraformer-large 精修,不阻塞转写")
                    RemoteSamplingSettings(sampling: $config.remoteAsr.sampling)
                }
            }

            Section("路径") {
                PathOverrideRow(
                    title: "模型目录",
                    hint: "留空 = 默认 ~/Library/Application Support/Transcriber/models"
                        + "(TRANSCRIBER_MODELS 环境变量优先级更高,用于开发调试)",
                    path: $config.paths.modelsDir
                )
                PathOverrideRow(
                    title: "录音/转写输出目录",
                    hint: "留空 = 默认 ~/Documents/Transcriber",
                    path: $config.paths.recordingsRoot
                )
            }

            Section {
                HStack {
                    Button("恢复默认值") {
                        config = TranscriberConfig()
                    }
                    Spacer()
                    if justSaved {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
                Text("改动对当前正在进行的转写不生效,下次点「开始转写」时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }

    private func save() {
        do {
            try ConfigStore.save(config)
            saveError = nil
            justSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { justSaved = false }
        } catch {
            saveError = "保存失败:\(error.localizedDescription)"
        }
    }
}

private struct RemoteSamplingSettings: View {
    @Binding var sampling: TranscriberConfig.RemoteAsr.Sampling
    /// temperature 不在可选列表里:覆盖时强制启用(见 Sampling.effectiveSamplers)
    private let choices = [("top_k", "top-k"), ("top_p", "top-p"), ("min_p", "min-p")]

    var body: some View {
        Divider()
        Text("远程 Qwen 采样参数")
            .font(.headline)
        Toggle("覆盖服务器默认采样器", isOn: enabled)
        if enabled.wrappedValue {
            Text("按 top-k → top-p → min-p → 温度 的固定顺序执行；温度始终启用；未勾选的数值不会发送给服务器。")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(choices, id: \.0) { key, title in
                Toggle(title, isOn: selected(key))
            }
            NumberField(title: "温度", value: $sampling.temperature, range: 0...2, step: 0.05)
            if sampling.samplers.contains("top_k") {
                Stepper("top-k：\(sampling.topK)", value: $sampling.topK, in: 0...200)
            }
            if sampling.samplers.contains("top_p") {
                NumberField(title: "top-p", value: $sampling.topP, range: 0...1, step: 0.01)
            }
            if sampling.samplers.contains("min_p") {
                NumberField(title: "min-p", value: $sampling.minP, range: 0...1, step: 0.01)
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { !sampling.samplers.isEmpty },
            set: { enabled in sampling.samplers = enabled ? TranscriberConfig.RemoteAsr.Sampling.order : [] })
    }

    private func selected(_ key: String) -> Binding<Bool> {
        Binding(
            get: { sampling.samplers.contains(key) },
            set: { selected in
                var set = Set(sampling.effectiveSamplers)
                if selected { set.insert(key) } else { set.remove(key) }
                // 经 order 过滤后写回:保持规范顺序,且 temperature 始终在,开关不会因取消所有勾选而关掉
                sampling.samplers = TranscriberConfig.RemoteAsr.Sampling.order.filter {
                    $0 == "temperature" || set.contains($0)
                }
            })
    }
}

private struct NumberField: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number.precision(.fractionLength(2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct PathOverrideRow: View {
    let title: String
    let hint: String
    @Binding var path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button("选择文件夹…") { choose() }
                if path != nil {
                    Button("恢复默认") { path = nil }
                }
            }
            if let path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

/// 和 PathOverrideRow 一样,但选文件而不是文件夹(证书/模型包这类)
private struct FilePathOverrideRow: View {
    let title: String
    let hint: String
    @Binding var path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button("选择文件…") { choose() }
                if path != nil {
                    Button("清空") { path = nil }
                }
            }
            if let path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // 不按扩展名过滤:.p12/.crt/.pem 这些不是 macOS 系统预注册的 UTType,
        // UTType(filenameExtension:) 解析不出来会变成奇怪的动态类型,导致这些文件
        // 在面板里被整体灰掉选不中(2026-09-16 实测踩过)。证书文件本来种类就杂,
        // 不筛选、让用户自己认文件名更可靠。
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
