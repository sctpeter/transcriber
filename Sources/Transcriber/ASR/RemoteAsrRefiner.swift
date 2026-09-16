import Foundation
import Security

/// 临时诊断用:直接写文件,不依赖 NSLog/统一日志系统(这次调试发现 `log stream`
/// 在这台机器上不可靠,有时候整段时间抓不到任何 App 自己的日志)。
/// 排查完这次的问题后应该删掉。
private func debugFileLog(_ message: String) {
    let path = "/tmp/transcriber_remote_debug.log"
    let line = "\(Date()) \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// 远程 Qwen3-ASR-1.7B Q8 精修器。协议细节见 docs/0003_remote_qwen3_asr_protocol.md,
/// 摘要:
///
///   - 一条 WSS 长连接,TLS 加密 + 用私有 CA 校验服务端身份(不依赖系统信任库,
///     见 urlSession(_:didReceive:completionHandler:))。客户端证书(双向 mTLS)
///     是可选的,由 config.remoteAsr.clientIdentityPath 是否配置决定——2026-09-16
///     定的策略:私有局域网、人数少,不需要认证"是谁在连",服务端(见
///     server/qwen3_asr_gateway.py)同理按 --ca 是否传入决定要不要验客户端证书,
///     两边都是配置开关,不是各自硬编码。
///   - 逐段(utterance)请求/响应,不是连续流式:Qwen3-ASR 本身不支持分块增量输入
///     (16kHz mono WAV 整段喂入),这和 VAD 已经把音频切成完整语句的现状天然吻合。
///   - 每段:一条 JSON 控制帧(.string)紧跟一条二进制帧(.data,int16 PCM),
///     服务端回一条 JSON 结果帧。
///   - fail-open:未连接/超时/出错,一律回退到本地 `OfflineRefiner`,不阻塞录音、
///     不丢句子;网络断开时后台指数退避重连。
///   - 顺序保证:completion 严格按 refine() 被调用的顺序触发,即使远程结果乱序返回
///     或中途有的段落走了本地兜底、有的段落走了远程(见 `order` FIFO + `drain()`)。
final class RemoteAsrRefiner: NSObject, SegmentRefiner {
    /// 连接状态变化时回调(true=已连接,false=断线/重连中,当前段落会回退本地)。
    /// 在主线程触发,给 UI 用(见 AppState.asrBackendStatus)。
    ///
    /// ⚠️ didSet 里会立刻用*当前*真实状态补触发一次:construct 之后连接是在
    /// 自己的后台队列上异步发起的,调用方(AppState)要等 Task.detached 跑完才会
    /// 设置这个回调,这段时间差里连接完全可能已经握手成功——如果不补触发,
    /// 第一次"已连接"的状态变化会在回调还是 nil 时发生、被无声吞掉,UI 永远停在
    /// 初始的"离线"状态(2026-09-16 实测踩过这个坑)。
    var onConnectionChange: ((Bool) -> Void)? {
        didSet {
            guard let callback = onConnectionChange else { return }
            queue.async { [weak self] in
                guard let self else { return }
                let current = self.connected
                DispatchQueue.main.async { callback(current) }
            }
        }
    }

    private let config: TranscriberConfig.RemoteAsr
    /// 协议类型而不是具体的 OfflineRefiner:生产环境传真的本地精修器,
    /// 测试(test/test_remote_asr.sh)传一个不需要真实模型文件的哑实现即可。
    private let localFallback: SegmentRefiner
    private let queue = DispatchQueue(label: "transcriber.remote-asr", qos: .userInitiated)

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var identity: SecIdentity?
    private var pinnedCA: SecCertificate?
    private var nextSegmentID: UInt64 = 0
    private var reconnectDelay: TimeInterval = 1
    private var connected = false

    /// 顺序队列:严格按 refine() 调用顺序排队,不管远程结果/本地兜底谁先算完,
    /// 都要等排在前面的段落先触发 completion(见 resolve/drain)。
    private final class PendingSegment {
        let id: UInt64
        let samples: [Float]
        let completion: (String) -> Void
        var result: String?
        var timeoutWorkItem: DispatchWorkItem?
        init(id: UInt64, samples: [Float], completion: @escaping (String) -> Void) {
            self.id = id
            self.samples = samples
            self.completion = completion
        }
    }
    private var order: [PendingSegment] = []

    init(config: TranscriberConfig.RemoteAsr, localFallback: SegmentRefiner) {
        self.config = config
        self.localFallback = localFallback
        super.init()
        debugFileLog("init() called, thread=\(Thread.current), isMain=\(Thread.isMainThread)")
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        loadIdentityAndCA()
        debugFileLog("init() after loadIdentityAndCA, pinnedCA=\(pinnedCA != nil), identity=\(identity != nil)")
        queue.async { [self] in connect() }
    }

    // MARK: - SegmentRefiner

    func refine(samples: [Float], completion: @escaping (String) -> Void) {
        queue.async { [self] in
            let seg = PendingSegment(id: nextSegmentID, samples: samples, completion: completion)
            nextSegmentID += 1
            order.append(seg)

            // identity(客户端证书)不是必需的,见 loadIdentityAndCA 的注释
            guard connected, let task, pinnedCA != nil else {
                fallbackToLocal(seg)
                return
            }
            send(segment: seg, on: task)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                NSLog(
                    "RemoteAsrRefiner: segment \(seg.id) 超过 \(config.timeoutSeconds)s 未返回,回退本地精修"
                )
                self.fallbackToLocal(seg)
            }
            seg.timeoutWorkItem = timeout
            queue.asyncAfter(deadline: .now() + Double(config.timeoutSeconds), execute: timeout)
        }
    }

    func enqueueOrdered(_ block: @escaping () -> Void) {
        // 只在"没有音频可精修"的兜底场景用(见 AsrEngine.finish()),不涉及网络,
        // 直接接到本地 refiner 的串行队列上,但仍要走 order FIFO 保持相对顺序。
        queue.async { [self] in
            let seg = PendingSegment(id: nextSegmentID, samples: []) { _ in block() }
            nextSegmentID += 1
            order.append(seg)
            localFallback.enqueueOrdered { [weak self] in
                self?.queue.async {
                    seg.result = ""
                    self?.drain()
                }
            }
        }
    }

    func waitUntilDrained() {
        queue.sync {}
        localFallback.waitUntilDrained()
    }

    // MARK: - 顺序 FIFO

    /// 必须在 `queue` 上调用
    private func fallbackToLocal(_ seg: PendingSegment) {
        seg.timeoutWorkItem?.cancel()
        localFallback.refine(samples: seg.samples) { [weak self] text in
            self?.queue.async {
                guard let self else { return }
                // 可能已经被远端结果抢先 resolve 过了(超时兜底和远端结果赛跑)
                guard seg.result == nil else { return }
                seg.result = text
                self.drain()
            }
        }
    }

    /// 必须在 `queue` 上调用。远端结果到达时调这个。
    private func resolve(id: UInt64, text: String) {
        guard let seg = order.first(where: { $0.id == id }) else { return }  // 已经超时兜底过了
        seg.timeoutWorkItem?.cancel()
        seg.result = text
        drain()
    }

    /// 必须在 `queue` 上调用。把队头已经有结果的段落依次弹出触发 completion。
    private func drain() {
        while let first = order.first, let result = first.result {
            order.removeFirst()
            first.completion(result)
        }
    }

    // MARK: - 连接管理

    private func connect() {
        debugFileLog("connect() called, serverURL=\(config.serverURL), pinnedCA=\(pinnedCA != nil)")
        // identity(客户端证书)不是必需的,见 loadIdentityAndCA 的注释;CA 是必需的。
        guard let url = URL(string: config.serverURL), pinnedCA != nil else {
            NSLog("RemoteAsrRefiner: 未正确配置(serverURL/CA),本次会话全部走本地精修")
            debugFileLog("connect() bailed out on guard")
            return
        }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        debugFileLog("connect() resumed webSocketTask")
        receiveLoop(on: t)
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.queue.async {
                    debugFileLog("receive failure: \(error)")
                    let nsError = error as NSError
                    NSLog(
                        "RemoteAsrRefiner: 连接中断(\(nsError.domain) \(nsError.code)): \(error.localizedDescription),后台重连中"
                    )
                    self.setConnected(false)
                    self.scheduleReconnect()
                }
            case .success(let message):
                self.handle(message)
                self.receiveLoop(on: task)
            }
        }
    }

    /// 必须在 `queue` 上调用
    private func setConnected(_ value: Bool) {
        connected = value
        let callback = onConnectionChange
        DispatchQueue.main.async { callback?(value) }
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - 协议编解码(见 docs/0003)

    private func send(segment seg: PendingSegment, on task: URLSessionWebSocketTask) {
        var header: [String: Any] = [
            "type": "segment",
            "id": seg.id,
            "sample_rate": 16000,
            "format": "pcm_s16le",
            "num_samples": seg.samples.count,
        ]
        let selected = config.sampling.effectiveSamplers
        if !selected.isEmpty {
            header["sampling"] = [
                "samplers": selected,
                "temperature": max(0, min(2, config.sampling.temperature)),
                "top_k": max(0, min(200, config.sampling.topK)),
                "top_p": max(0, min(1, config.sampling.topP)),
                "min_p": max(0, min(1, config.sampling.minP)),
            ]
        }
        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
            let headerText = String(data: headerData, encoding: .utf8)
        else { return }

        var pcm = Data(capacity: seg.samples.count * 2)
        for s in seg.samples {
            let clamped = max(-1, min(1, s))
            let i16 = Int16(clamped * 32767)
            withUnsafeBytes(of: i16.littleEndian) { pcm.append(contentsOf: $0) }
        }

        task.send(.string(headerText)) { [weak self] error in
            if let error {
                NSLog("RemoteAsrRefiner: 发送 header 失败: \(error.localizedDescription)")
                return
            }
            task.send(.data(pcm)) { error in
                if let error {
                    NSLog("RemoteAsrRefiner: 发送音频失败: \(error.localizedDescription)")
                    self?.queue.async { self?.fallbackToLocal(seg) }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return }

        switch type {
        case "result":
            guard let idNum = obj["id"] as? UInt64 ?? (obj["id"] as? NSNumber)?.uint64Value,
                let resultText = obj["text"] as? String
            else { return }
            queue.async { [self] in resolve(id: idNum, text: resultText) }
        case "error":
            let idNum = obj["id"] as? UInt64 ?? (obj["id"] as? NSNumber)?.uint64Value
            let msg = obj["message"] as? String ?? "未知错误"
            NSLog("RemoteAsrRefiner: 服务端返回错误(segment \(idNum.map(String.init) ?? "?")): \(msg)")
            if let idNum {
                queue.async { [self] in
                    guard let seg = order.first(where: { $0.id == idNum }) else { return }
                    fallbackToLocal(seg)
                }
            }
        default:
            break
        }
    }

    // MARK: - TLS 身份加载
    //
    // 客户端证书(mTLS 的"双向"那一半)是可选的,由 `clientIdentityPath` 是否配置
    // 决定,不是写死开/关——2026-09-16 定的策略:私有局域网、人数少,不需要认证
    // "是谁在连",只需要保证数据传输加密、以及客户端能验证自己连的是真服务器
    // (下面的 CA 校验)。以后要重新收紧成双向认证,直接在设置面板填上客户端证书
    // 路径就行,不用改代码——`server/qwen3_asr_gateway.py` 那边同理,`--ca` 参数
    // 决定要不要校验客户端证书,一个开关对应两端,不是各自硬编码一套逻辑。

    private func loadIdentityAndCA() {
        if !config.clientIdentityPath.isEmpty {
            loadClientIdentity()
        }

        // CA 校验服务端身份是必须的,不管客户端证书要不要用都得有,否则等于裸奔连接
        guard !config.caCertPath.isEmpty,
            let caData = try? Data(contentsOf: URL(fileURLWithPath: config.caCertPath)),
            let ca = Self.certificate(fromPEMOrDER: caData)
        else {
            NSLog("RemoteAsrRefiner: CA 证书(remoteAsr.caCertPath)加载失败,本次会话全部走本地精修")
            return
        }
        pinnedCA = ca
    }

    private func loadClientIdentity() {
        guard let p12Data = try? Data(contentsOf: URL(fileURLWithPath: config.clientIdentityPath))
        else {
            NSLog("RemoteAsrRefiner: 客户端证书文件读取失败(\(config.clientIdentityPath)),本次会话不出示客户端证书")
            return
        }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: config.clientIdentityPassword]
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
            let array = items as? [[String: Any]],
            let first = array.first,
            let identityRef = first[kSecImportItemIdentity as String]
        else {
            NSLog("RemoteAsrRefiner: 客户端证书(.p12)加载失败,status=\(status),本次会话不出示客户端证书")
            return
        }
        // SecPKCS12Import 保证这个 key 存在时值就是 SecIdentity,CF 类型经桥接后可以强转
        identity = (identityRef as! SecIdentity)
    }

    /// SecCertificateCreateWithData 只吃 DER;make_remote_asr_certs.sh 产出的是 PEM,
    /// 这里两种都兼容,不强求调用方转格式。
    private static func certificate(fromPEMOrDER data: Data) -> SecCertificate? {
        if let cert = SecCertificateCreateWithData(nil, data as CFData) {
            return cert
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let base64 = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}

extension RemoteAsrRefiner: URLSessionDelegate {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        debugFileLog("didReceive challenge, method=\(challenge.protectionSpace.authenticationMethod)")
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let serverTrust = challenge.protectionSpace.serverTrust, let pinnedCA else {
                debugFileLog("ServerTrust guard failed")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // 只信我们自己的私有 CA,不信系统信任库(见 docs/0003:这是内部通道,不是公网服务)。
            // 这一步不管要不要客户端证书都要做——不然连的服务器身份都没法保证。
            SecTrustSetAnchorCertificates(serverTrust, [pinnedCA] as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)
            if SecTrustEvaluateWithError(serverTrust, nil) {
                debugFileLog("ServerTrust passed")
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                NSLog("RemoteAsrRefiner: 服务端证书未通过私有 CA 校验,拒绝连接")
                debugFileLog("ServerTrust FAILED")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            // 没配置客户端证书是正常情况(见 loadIdentityAndCA 的注释,mTLS 已改成可选),
            // 用 performDefaultHandling 让 TLS 层按"不出示证书"继续走,不是错误。
            guard let identity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

extension RemoteAsrRefiner: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        debugFileLog("didOpenWithProtocol fired")
        queue.async { [self] in
            setConnected(true)
            reconnectDelay = 1
            NSLog("RemoteAsrRefiner: 已连接 \(config.serverURL)")
        }
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        queue.async { [self] in
            setConnected(false)
            scheduleReconnect()
        }
    }
}
