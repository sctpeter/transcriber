import Foundation

/// 统一可调参数。默认值 = 改造前散落在各文件里的硬编码值,行为不变。
///
/// 落盘位置:~/Library/Application Support/Transcriber/config.json
/// 读取时机:每次 AppState.startRecording() 重新读一次盘(引擎本就每次录制重建),
/// 因此改动"下次开始转写"即生效,无需重启 App。
struct TranscriberConfig: Codable, Equatable {
    struct VAD: Codable, Equatable {
        /// Silero VAD 语音概率阈值,越低越容易判定为"在说话"
        var threshold: Float = 0.5
        /// 判定一句话结束所需的静音时长(秒)
        var minSilenceDuration: Float = 0.8
        /// 计入"语音"所需的最短时长(秒),过滤掉短促噪声
        var minSpeechDuration: Float = 0.25
        /// 单句强制切分的时长上限(秒),防止长时间不停顿导致段落无限增长
        var maxSpeechDuration: Float = 28.0
        /// VAD 分析窗口大小(采样点数),Silero VAD 仅支持 256 / 512
        var windowSize: Int = 512

        init() {}

        private enum CodingKeys: String, CodingKey {
            case threshold, minSilenceDuration, minSpeechDuration, maxSpeechDuration, windowSize
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            threshold = try c.decodeIfPresent(Float.self, forKey: .threshold) ?? Self().threshold
            minSilenceDuration =
                try c.decodeIfPresent(Float.self, forKey: .minSilenceDuration)
                ?? Self().minSilenceDuration
            minSpeechDuration =
                try c.decodeIfPresent(Float.self, forKey: .minSpeechDuration)
                ?? Self().minSpeechDuration
            maxSpeechDuration =
                try c.decodeIfPresent(Float.self, forKey: .maxSpeechDuration)
                ?? Self().maxSpeechDuration
            windowSize = try c.decodeIfPresent(Int.self, forKey: .windowSize) ?? Self().windowSize
        }
    }

    struct ASR: Codable, Equatable {
        /// 流式 + 离线精修识别器共用的线程数
        var numThreads: Int = 2
        /// 推理执行后端,当前预编译库只含 cpu
        var provider: String = "cpu"
        // 不再提供 decodingMethod:本地流式/离线模型都是 paraformer(非自回归),sherpa-onnx
        // 只支持 greedy_search;设成 modified_beam_search 会在 C++ 里直接 exit(-1) 闪退
        // (见 docs/0007)。旧 config.json 里残留的该字段解码时被忽略,下次保存即清除。

        init() {}

        private enum CodingKeys: String, CodingKey {
            case numThreads, provider
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            numThreads = try c.decodeIfPresent(Int.self, forKey: .numThreads) ?? Self().numThreads
            provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? Self().provider
        }
    }

    struct Paths: Codable, Equatable {
        /// 模型搜索目录覆盖。nil = 使用默认查找顺序(见 AsrModels.searchPaths)。
        /// 注意:TRANSCRIBER_MODELS 环境变量优先级高于此项(开发/自测用)。
        var modelsDir: String?
        /// 录音/转写输出根目录覆盖。nil = ~/Documents/Transcriber
        var recordingsRoot: String?

        init() {}

        private enum CodingKeys: String, CodingKey {
            case modelsDir, recordingsRoot
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modelsDir = try c.decodeIfPresent(String.self, forKey: .modelsDir)
            recordingsRoot = try c.decodeIfPresent(String.self, forKey: .recordingsRoot)
        }
    }

    struct Denoise: Codable, Equatable {
        struct HighPass: Codable, Equatable {
            /// 是否启用高通滤波(RBJ 一阶/二阶 biquad,在原生采样率下、重采样之前执行)
            var enabled: Bool = false
            /// 截止频率(Hz)。默认 80Hz:压低桌面震动/电源哼声等低频底噪,基本不伤语音频段
            var cutoffHz: Float = 80.0

            init() {}

            private enum CodingKeys: String, CodingKey { case enabled, cutoffHz }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self().enabled
                cutoffHz = try c.decodeIfPresent(Float.self, forKey: .cutoffHz) ?? Self().cutoffHz
            }
        }

        struct DeepFilterNet: Codable, Equatable {
            /// 是否启用 DeepFilterNet3 深度降噪(仅在原生采样率为 48kHz 时生效,见 docs/0002)
            var enabled: Bool = false
            /// 最大衰减量(dB)。数值越大降噪越强,但底噪削得越狠时越容易伤语音/引入 artifact
            var attenLimitDb: Float = 30.0
            /// DeepFilterNet3 模型包路径(tar.gz,内含 onnx 权重)。
            /// 留空 = 使用 libdf 内置的默认 DFN3 模型(cargo `default-model` feature 编译进库里)
            var modelPath: String?

            init() {}

            private enum CodingKeys: String, CodingKey { case enabled, attenLimitDb, modelPath }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self().enabled
                attenLimitDb =
                    try c.decodeIfPresent(Float.self, forKey: .attenLimitDb) ?? Self().attenLimitDb
                modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath)
            }
        }

        var highPass = HighPass()
        var deepFilterNet = DeepFilterNet()

        init() {}

        private enum CodingKeys: String, CodingKey { case highPass, deepFilterNet }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            highPass = try c.decodeIfPresent(HighPass.self, forKey: .highPass) ?? HighPass()
            deepFilterNet =
                try c.decodeIfPresent(DeepFilterNet.self, forKey: .deepFilterNet) ?? DeepFilterNet()
        }
    }

    struct RemoteAsr: Codable, Equatable {
        struct Sampling: Codable, Equatable {
            /// 固定执行顺序;temperature 在覆盖时强制启用(见 effectiveSamplers)
            static let order = ["top_k", "top_p", "min_p", "temperature"]

            /// 空数组 = 不覆盖服务器默认采样器。非空时按固定顺序组合为 llama-server 的 samplers。
            var samplers: [String] = []
            // 默认值对齐 wangtian03 上 llama-server 的实际默认(/props,2026-09-16):
            // 服务器 temperature≈1e-6,这里取 0,实测两者输出一致(都近似贪心)。
            var temperature: Float = 0
            var topK: Int = 40
            var topP: Float = 0.95
            var minP: Float = 0.05

            init() {}

            /// 实际发送的采样器链:按固定顺序去重,覆盖启用时总是包含 temperature。
            /// 不含 temperature 时 llama.cpp 等价于温度 1 随机抽样,会让识别结果明显不稳定,
            /// 所以即使旧 config.json 里漏了它也在这里补上。
            var effectiveSamplers: [String] {
                guard !samplers.isEmpty else { return [] }
                return Self.order.filter { $0 == "temperature" || samplers.contains($0) }
            }

            private enum CodingKeys: String, CodingKey { case samplers, temperature, topK, topP, minP }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                samplers = try c.decodeIfPresent([String].self, forKey: .samplers) ?? Self().samplers
                temperature = try c.decodeIfPresent(Float.self, forKey: .temperature) ?? Self().temperature
                topK = try c.decodeIfPresent(Int.self, forKey: .topK) ?? Self().topK
                topP = try c.decodeIfPresent(Float.self, forKey: .topP) ?? Self().topP
                minP = try c.decodeIfPresent(Float.self, forKey: .minP) ?? Self().minP
            }
        }

        /// 精修(final)是否走远程 Qwen3-ASR,而不是本地 paraformer-large。
        /// partial 永远走本地流式模型,不受此项影响(见 docs/0003)。
        var enabled: Bool = false
        /// wss:// 地址,例如 wss://asr.internal.example.com:8765/v1/transcribe
        var serverURL: String = ""
        /// 客户端证书(.p12,内含私钥+证书链),用于双向 mTLS 认证。
        /// 可选:留空 = 不出示客户端证书,只做单向 TLS(仍然校验服务端身份,
        /// 只是不认证客户端是谁)——2026-09-16 定的默认策略,私有局域网、人数少,
        /// 服务端(server/qwen3_asr_gateway.py)按 --ca 是否传入配套决定要不要验。
        /// 想重新收紧成双向认证,两边都是配置开关,不用改代码。
        var clientIdentityPath: String = ""
        /// .p12 的密码。存明文在本地 config.json 里,权限等同于本机磁盘访问权限
        var clientIdentityPassword: String = ""
        /// 签发服务器证书的 CA 根证书(.pem/.der),用于校验服务端身份(不依赖系统信任库)
        var caCertPath: String = ""
        /// 请求超时(秒),超时按本地 paraformer-large 兜底(不阻塞转写)
        var timeoutSeconds: Float = 8.0
        /// 远程 llama-server 的逐段采样设置；空采样器列表表示使用服务器默认值。
        var sampling = Sampling()

        init() {}

        private enum CodingKeys: String, CodingKey {
            case enabled, serverURL, clientIdentityPath, clientIdentityPassword, caCertPath,
                timeoutSeconds, sampling
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self().enabled
            serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? Self().serverURL
            clientIdentityPath =
                try c.decodeIfPresent(String.self, forKey: .clientIdentityPath)
                ?? Self().clientIdentityPath
            clientIdentityPassword =
                try c.decodeIfPresent(String.self, forKey: .clientIdentityPassword)
                ?? Self().clientIdentityPassword
            caCertPath = try c.decodeIfPresent(String.self, forKey: .caCertPath) ?? Self().caCertPath
            timeoutSeconds =
                try c.decodeIfPresent(Float.self, forKey: .timeoutSeconds) ?? Self().timeoutSeconds
            sampling = try c.decodeIfPresent(Sampling.self, forKey: .sampling) ?? Sampling()
        }
    }

    var vad = VAD()
    var asr = ASR()
    var paths = Paths()
    var denoise = Denoise()
    var remoteAsr = RemoteAsr()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case vad, asr, paths, denoise, remoteAsr
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vad = try c.decodeIfPresent(VAD.self, forKey: .vad) ?? VAD()
        asr = try c.decodeIfPresent(ASR.self, forKey: .asr) ?? ASR()
        paths = try c.decodeIfPresent(Paths.self, forKey: .paths) ?? Paths()
        denoise = try c.decodeIfPresent(Denoise.self, forKey: .denoise) ?? Denoise()
        remoteAsr = try c.decodeIfPresent(RemoteAsr.self, forKey: .remoteAsr) ?? RemoteAsr()
    }
}

/// 单一入口:加载/保存/持有当前配置。AppState 在每次开始录制时读取一份快照,
/// SettingsView 编辑后立即落盘并更新 `current`(供 UI 显示"已保存"状态)。
enum ConfigStore {
    /// 默认 ~/Library/Application Support/Transcriber/config.json;
    /// TRANSCRIBER_CONFIG 环境变量可覆盖(测试/多套参数用,与 TRANSCRIBER_MODELS 同思路)。
    static var fileURL: URL {
        if let env = ProcessInfo.processInfo.environment["TRANSCRIBER_CONFIG"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// 从磁盘加载,文件不存在/损坏时返回默认值(不会抛错、不会阻塞启动)
    static func load() -> TranscriberConfig {
        guard let data = try? Data(contentsOf: fileURL) else { return TranscriberConfig() }
        return (try? JSONDecoder().decode(TranscriberConfig.self, from: data)) ?? TranscriberConfig()
    }

    static func save(_ config: TranscriberConfig) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}
