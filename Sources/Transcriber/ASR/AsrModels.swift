import Foundation

/// 模型文件定位。查找顺序:
/// 1. TRANSCRIBER_MODELS 环境变量(selftest / 开发用,只读定位)
/// 2. ~/Library/Application Support/Transcriber/models(app 内下载的落盘位置)
struct AsrModels {
    /// §4.6 定型:本地实时默认 = 流式双语 Paraformer int8
    let streamingEncoder: URL
    let streamingDecoder: URL
    let streamingTokens: URL
    /// §4.6 定型:精修 final = FunASR paraformer-large int8
    let offlineModel: URL
    let offlineTokens: URL
    /// Silero VAD
    let vadModel: URL

    /// 查找顺序:1) TRANSCRIBER_MODELS 环境变量 2) config.json 里的 paths.modelsDir
    /// 3) ~/Library/Application Support/Transcriber/models(app 内下载的落盘位置)
    static func searchPaths(config: TranscriberConfig) -> [URL] {
        var paths: [URL] = []
        if let env = ProcessInfo.processInfo.environment["TRANSCRIBER_MODELS"] {
            paths.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let dir = config.paths.modelsDir, !dir.isEmpty {
            paths.append(URL(fileURLWithPath: dir, isDirectory: true))
        }
        paths.append(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Transcriber/models", isDirectory: true))
        return paths
    }

    static func locate(config: TranscriberConfig = ConfigStore.load()) throws -> AsrModels {
        let streamingDir = "sherpa-onnx-streaming-paraformer-bilingual-zh-en"
        let offlineDir = "sherpa-onnx-paraformer-zh-2023-09-14"
        let required = [
            "\(streamingDir)/encoder.int8.onnx",
            "\(streamingDir)/decoder.int8.onnx",
            "\(streamingDir)/tokens.txt",
            "\(offlineDir)/model.int8.onnx",
            "\(offlineDir)/tokens.txt",
            "silero_vad.onnx",
        ]

        let roots = searchPaths(config: config)
        for root in roots {
            let fm = FileManager.default
            if required.allSatisfy({ fm.fileExists(atPath: root.appendingPathComponent($0).path) }) {
                return AsrModels(
                    streamingEncoder: root.appendingPathComponent("\(streamingDir)/encoder.int8.onnx"),
                    streamingDecoder: root.appendingPathComponent("\(streamingDir)/decoder.int8.onnx"),
                    streamingTokens: root.appendingPathComponent("\(streamingDir)/tokens.txt"),
                    offlineModel: root.appendingPathComponent("\(offlineDir)/model.int8.onnx"),
                    offlineTokens: root.appendingPathComponent("\(offlineDir)/tokens.txt"),
                    vadModel: root.appendingPathComponent("silero_vad.onnx")
                )
            }
        }
        throw AsrError.modelsNotFound(searched: roots.map(\.path))
    }
}

enum AsrError: LocalizedError {
    case modelsNotFound(searched: [String])

    var errorDescription: String? {
        switch self {
        case .modelsNotFound(let searched):
            return """
                未找到 ASR 模型。已查找:\(searched.joined(separator: ", "))。
                请在 Transcriber 主窗口点击「下载模型」。
                """
        }
    }
}
