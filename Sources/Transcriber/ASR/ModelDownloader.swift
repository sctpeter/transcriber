import Foundation

/// 模型组件:检测缺失 + 官方下载源(sherpa-onnx GitHub release "asr-models")
enum ModelComponent: CaseIterable {
    case streaming  // 流式双语 Paraformer(partial)
    case offline  // FunASR paraformer-large(final 精修)
    case vad  // Silero VAD

    static let releaseBase =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"

    var title: String {
        switch self {
        case .streaming: return "流式识别模型 (1.0GB)"
        case .offline: return "离线精修模型 (234MB)"
        case .vad: return "VAD 模型 (0.6MB)"
        }
    }

    var url: URL {
        switch self {
        case .streaming:
            return URL(
                string: Self.releaseBase
                    + "sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2")!
        case .offline:
            return URL(string: Self.releaseBase + "sherpa-onnx-paraformer-zh-2023-09-14.tar.bz2")!
        case .vad:
            return URL(string: Self.releaseBase + "silero_vad.onnx")!
        }
    }

    var isArchive: Bool { self != .vad }

    /// 相对模型根目录的必需文件(与 AsrModels.locate 一致)
    var requiredFiles: [String] {
        switch self {
        case .streaming:
            return [
                "sherpa-onnx-streaming-paraformer-bilingual-zh-en/encoder.int8.onnx",
                "sherpa-onnx-streaming-paraformer-bilingual-zh-en/decoder.int8.onnx",
                "sherpa-onnx-streaming-paraformer-bilingual-zh-en/tokens.txt",
            ]
        case .offline:
            return [
                "sherpa-onnx-paraformer-zh-2023-09-14/model.int8.onnx",
                "sherpa-onnx-paraformer-zh-2023-09-14/tokens.txt",
            ]
        case .vad:
            return ["silero_vad.onnx"]
        }
    }

    /// 解压后删除的冗余内容(fp32 权重、测试音频),磁盘占用 1.4GB → 460MB
    var pruneAfterExtract: [String] {
        switch self {
        case .streaming:
            return [
                "sherpa-onnx-streaming-paraformer-bilingual-zh-en/encoder.onnx",
                "sherpa-onnx-streaming-paraformer-bilingual-zh-en/decoder.onnx",
                "sherpa-onnx-streaming-paraformer-bilingual-zh-en/test_wavs",
            ]
        case .offline:
            return ["sherpa-onnx-paraformer-zh-2023-09-14/test_wavs"]
        case .vad:
            return []
        }
    }

    /// 下载量估计(整体进度条按此加权)
    var approxBytes: Int64 {
        switch self {
        case .streaming: return 1_047_000_000
        case .offline: return 234_000_000
        case .vad: return 650_000
        }
    }
}

enum ModelFetchError: LocalizedError {
    case badResponse(Int)
    case extractFailed

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "服务器返回 \(code)"
        case .extractFailed: return "解压失败"
        }
    }
}

/// 无 UI 的下载/解压核心(仅供 app 内 ModelDownloader 使用)
enum ModelFetcher {
    /// 下载目标目录:固定为真实的 App Support,不受环境变量/临时目录影响
    static var appSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber/models", isDirectory: true)
    }

    /// 确保下载根目录是真实目录:开发期遗留的 symlink(可能悬空)一律替换,
    /// 避免权重落进外部临时目录、目录被删后 app 失效
    static func prepareRoot(_ root: URL) throws {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: root.path)) != nil {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func missingComponents(root: URL) -> [ModelComponent] {
        let fm = FileManager.default
        return ModelComponent.allCases.filter { c in
            !c.requiredFiles.allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        }
    }

    static func fetch(
        _ component: ModelComponent, to root: URL,
        delegate: URLSessionTaskDelegate? = nil
    ) async throws {
        let (tmp, response) = try await URLSession.shared.download(
            from: component.url, delegate: delegate)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ModelFetchError.badResponse(http.statusCode)
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        if component.isArchive {
            try await extractTar(tmp, into: root)
            for rel in component.pruneAfterExtract {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(rel))
            }
        } else {
            let dest = root.appendingPathComponent(component.requiredFiles[0])
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
    }

    /// tar 自动识别 bz2(下载临时文件无扩展名也没问题)
    private static func extractTar(_ archive: URL, into dir: URL) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["xf", archive.path, "-C", dir.path]
        try proc.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }
        guard proc.terminationStatus == 0 else { throw ModelFetchError.extractFailed }
    }
}

/// GUI 状态包装:检测 → 顺序下载缺失组件 → 进度发布
@MainActor
final class ModelDownloader: NSObject, ObservableObject {
    @Published var modelsReady: Bool
    @Published var isDownloading = false
    @Published var statusText = ""
    @Published var progress: Double = 0

    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 1

    override init() {
        modelsReady = (try? AsrModels.locate()) != nil
        super.init()
    }

    /// 缺失组件的总下载量(GB 字符串,按钮文案用)
    var missingSizeText: String {
        let bytes = ModelFetcher.missingComponents(root: ModelFetcher.appSupportRoot)
            .map(\.approxBytes).reduce(0, +)
        return String(format: "%.1fGB", Double(bytes) / 1_000_000_000)
    }

    func start() {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        Task {
            defer { isDownloading = false }
            do {
                let root = ModelFetcher.appSupportRoot
                try ModelFetcher.prepareRoot(root)
                let missing = ModelFetcher.missingComponents(root: root)
                totalBytes = max(1, missing.map(\.approxBytes).reduce(0, +))
                completedBytes = 0
                for (i, component) in missing.enumerated() {
                    statusText = "下载 \(i + 1)/\(missing.count):\(component.title)"
                    try await ModelFetcher.fetch(component, to: root, delegate: self)
                    completedBytes += component.approxBytes
                    progress = Double(completedBytes) / Double(totalBytes)
                }
                modelsReady = (try? AsrModels.locate()) != nil
                statusText = modelsReady ? "" : "下载完成但文件校验未通过,请重试"
            } catch {
                statusText = "下载失败:\(error.localizedDescription)"
            }
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            progress = min(
                1, Double(completedBytes + totalBytesWritten) / Double(totalBytes))
        }
    }

    /// async download(from:delegate:) 自行处理落盘,这里仅为满足协议
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
