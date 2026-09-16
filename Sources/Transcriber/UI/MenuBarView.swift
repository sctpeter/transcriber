import SwiftUI

/// 菜单栏状态入口(计划 §2.4):状态一瞥 + 快捷开关,上课时不占屏幕
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appState.isRecording {
                Text("转写中 \(ContentView.format(appState.elapsed))")
                Button("停止转写") {
                    Task { await appState.stopRecording() }
                }
            } else {
                Text(appState.isPreparing ? "加载模型…" : "空闲")
                Button("开始转写") {
                    Task { await appState.startRecording() }
                }
                .disabled(appState.isPreparing)
            }

            Divider()

            Toggle("麦克风", isOn: $appState.micEnabled)
                .disabled(appState.isRecording)
            Toggle("系统音频", isOn: $appState.sysEnabled)
                .disabled(appState.isRecording)

            Divider()

            Button("显示录音文件") {
                appState.revealRecordings()
            }

            Divider()

            Button("退出") {
                Task {
                    await appState.stopRecording()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}
