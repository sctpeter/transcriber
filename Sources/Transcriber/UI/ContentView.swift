import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var downloader = ModelDownloader()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.isRecording {
                backendStatusBadge
            }

            HStack(spacing: 12) {
                SourceRow(
                    title: "麦克风",
                    systemImage: "mic.fill",
                    enabled: $appState.micEnabled,
                    active: appState.micActive,
                    level: appState.micLevel,
                    sampleRate: appState.micSampleRate,
                    isRecording: appState.isRecording
                )
                SourceRow(
                    title: "系统音频",
                    systemImage: "speaker.wave.2.fill",
                    enabled: $appState.sysEnabled,
                    active: appState.sysActive,
                    level: appState.sysLevel,
                    sampleRate: appState.sysSampleRate,
                    isRecording: appState.isRecording
                )
            }

            if !downloader.modelsReady {
                modelBanner
            }

            transcripts

            if let reason = appState.asrUnavailableReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if let error = appState.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            controls
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 460)
    }

    /// 当前 final 精修实际在用的后端——始终反映真实状态,不是配置意图
    /// (配置了远程但掉线回退本地时,显示的是"远程离线·已回退本地",不是"本地模型")
    private var backendStatusBadge: some View {
        let status = appState.asrBackendStatus
        return HStack(spacing: 6) {
            Image(systemName: status.systemImage)
            Text(status.label)
        }
        .font(.caption)
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12), in: Capsule())
    }

    /// 模型缺失横幅:一键下载到 App Support(下载中显示总进度)
    private var modelBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if downloader.isDownloading {
                HStack(spacing: 10) {
                    ProgressView(value: downloader.progress)
                    Text("\(Int(downloader.progress * 100))%")
                        .font(.system(.caption, design: .monospaced))
                }
                Text(downloader.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("ASR 模型未就绪,当前只能录音", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("下载模型(约 \(downloader.missingSizeText))") {
                        downloader.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if !downloader.statusText.isEmpty {
                    Text(downloader.statusText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 双源分栏字幕(计划 §2.3);单源时占满
    private var transcripts: some View {
        HStack(spacing: 12) {
            if appState.micEnabled {
                TranscriptView(
                    title: "麦克风转写",
                    finals: appState.micFinals,
                    partial: appState.micPartial
                )
            }
            if appState.sysEnabled {
                TranscriptView(
                    title: "系统音频转写",
                    finals: appState.sysFinals,
                    partial: appState.sysPartial
                )
            }
            if !appState.micEnabled && !appState.sysEnabled {
                ContentUnavailableView(
                    "未开启输入源", systemImage: "waveform.slash",
                    description: Text("打开上方的麦克风或系统音频开关"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if appState.isRecording {
                        await appState.stopRecording()
                    } else {
                        await appState.startRecording()
                    }
                }
            } label: {
                Label(
                    appState.isRecording
                        ? "停止转写" : (appState.isPreparing ? "加载模型…" : "开始转写"),
                    systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .frame(minWidth: 120)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .tint(appState.isRecording ? .red : .accentColor)
            .buttonStyle(.borderedProminent)
            .disabled(appState.isPreparing)

            if appState.isPreparing {
                ProgressView().controlSize(.small)
            }

            if appState.isRecording {
                Text(Self.format(appState.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.red)
            }

            Spacer()

            Button("在 Finder 中显示录音") {
                appState.revealRecordings()
            }
            .disabled(appState.lastSessionFolder == nil && appState.isRecording == false
                && !FileManager.default.fileExists(atPath: AppState.recordingsRoot.path))

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("设置(VAD / 识别参数 / 路径)")
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 单个输入源:开关 + 状态 + 电平表 + 实际采样率
struct SourceRow: View {
    let title: String
    let systemImage: String
    @Binding var enabled: Bool
    let active: Bool
    let level: Float
    let sampleRate: Double
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $enabled) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                }
                .toggleStyle(.switch)
                .disabled(isRecording)

                Spacer()

                if active {
                    Text(sampleRate > 0 ? "\(Int(sampleRate)) Hz" : "…")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
            LevelMeter(level: active ? level : 0)
                .frame(height: 6)
                .opacity(enabled ? 1 : 0.3)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}
