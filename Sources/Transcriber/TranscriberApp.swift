import Foundation
import SwiftUI

@main
struct TranscriberMain {
    static func main() {
        // 无头入口:不启动 GUI
        if CommandLine.arguments.contains("--print-config") {
            printConfig()  // 打印当前生效的 config.json(含默认值合并),便于排查"改动生效了吗"
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run(arguments: CommandLine.arguments)  // ASR 管线自测
        }
        if CommandLine.arguments.contains("--selftest-highpass") {
            SelfTest.runHighPassCheck()  // 高通滤波频响自测
        }
        if CommandLine.arguments.contains("--selftest-denoise-guard") {
            SelfTest.runDenoiseGuardCheck()  // DeepFilterNet3 模型缺失时的优雅降级自测
        }
        if CommandLine.arguments.contains("--selftest-denoise-real") {
            SelfTest.runDenoiseRealCheck(arguments: CommandLine.arguments)  // 真实模型跑通自测
        }
        if CommandLine.arguments.contains("--selftest-remote-asr") {
            SelfTest.runRemoteAsrCheck(arguments: CommandLine.arguments)  // 远程 ASR mTLS+协议自测
        }
        TranscriberApp.main()
    }

    private static func printConfig() {
        let config = ConfigStore.load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config),
            let json = String(data: data, encoding: .utf8)
        else {
            fputs("无法编码当前配置\n", stderr)
            exit(1)
        }
        print("配置文件: \(ConfigStore.fileURL.path)")
        print(json)
        exit(0)
    }
}

struct TranscriberApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("实时转写") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 520, height: 480)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "waveform.circle.fill" : "waveform.circle")
        }

        Settings {
            SettingsView()
        }
    }
}
