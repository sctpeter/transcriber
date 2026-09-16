import CDeepFilter
import Foundation

/// DeepFilterNet3 深度降噪,通过官方 libdf 的 C API 调用。
///
/// 硬约束(以 fetch_deepfilter.sh 实际编译产出的 v0.5.6 `deep_filter.h` 为准——
/// 注意 upstream `main` 分支的 capi.rs 比 v0.5.6 多了 log_level 参数和日志/系数查询
/// 接口,但那些改动还没随 tag 发布,`cargo capi build` 用的是 v0.5.6 tag,实际生成的
/// 头文件里 `df_create` 只有两个参数,以下按实际产出的头文件写,不是按 main 分支源码写):
/// - `df_create(path, atten_lim)` 内部固定 `channels = 1`、采样率由模型 tar.gz 里的
///   config.ini 决定(官方默认 DeepFilterNet3_onnx.tar.gz 是 48kHz),必须在原生 48kHz
///   上跑,不能在 16k 上跑,所以插在 `StreamingResampler` **之前**(见 AudioPreprocessor)。
/// - `path` 参数是必填的本地 tar.gz 文件路径,Rust 侧 `CStr::from_ptr(path)` 对空指针
///   直接崩溃,库内没有"留空用内置默认模型"的分支——即使 `default-model` feature 编译
///   进了默认权重,capi 层也没有暴露它。因此 `modelPath` 必须解析到一个真实存在的文件,
///   否则视为"本次会话不启用降噪"(fail-open,不阻断录音),而不是尝试传空指针。
/// - `df_process_frame` 必须严格按 `df_get_frame_length()` 返回的样本数喂,一次一帧,
///   多退少补由本类内部的环形缓冲处理,调用方只管喂任意长度的 chunk。
final class DeepFilterNetDenoiser {
    private let state: OpaquePointer
    let frameLength: Int
    private var pending: [Float] = []

    /// - Parameters:
    ///   - modelPath: DeepFilterNet3 tar.gz 模型包的本地路径(必须已存在)
    ///   - attenLimitDb: 最大衰减量(dB),越大降噪越强、越容易伤语音
    /// 返回 nil = 加载失败(文件缺失/损坏/libdf 内部 panic 保护外的路径未存在检查),
    /// 调用方应当把这当作"本次不启用降噪"处理,不能让整条录音管线崩掉。
    init?(modelPath: URL, attenLimitDb: Float) {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            NSLog("DeepFilterNetDenoiser: 模型文件不存在: \(modelPath.path)")
            return nil
        }
        // ⚠️ 已知上游限制:capi.rs 的 DFState::new 内部用 `.expect(...)`,tar.gz
        // 存在但内容损坏(缺 enc.onnx/erb_dec.onnx/config.ini 等)时是 Rust panic
        // 跨 FFI 边界直接 abort 整个进程,不是可捕获的错误——这里的文件存在性检查
        // 只能挡住"路径写错/文件缺失"这一类,挡不住"文件存在但损坏"。
        guard
            let created = modelPath.path.withCString({ pathC in
                df_create(pathC, attenLimitDb)
            })
        else {
            NSLog("DeepFilterNetDenoiser: df_create 失败(模型文件可能损坏): \(modelPath.path)")
            return nil
        }
        state = created
        // df_get_frame_length 返回 uintptr_t → Swift 里是 UInt,这里转成 Int 方便和
        // 数组下标/count 混用
        frameLength = Int(df_get_frame_length(state))
        pending.reserveCapacity(frameLength * 2)
    }

    deinit {
        df_free(state)
    }

    /// 原地风格接口:喂入任意长度的 48kHz 单声道采样,返回同样长度的降噪结果
    /// (内部按 frameLength 分帧处理,不足一帧的尾巴留到下次调用,首尾各有 frameLength
    /// 量级的延迟——和 Silero VAD 的 0.5s pre-roll 相比可以忽略)。
    func process(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        var output: [Float] = []
        output.reserveCapacity(samples.count)

        var inFrame = [Float](repeating: 0, count: frameLength)
        var outFrame = [Float](repeating: 0, count: frameLength)
        var consumed = 0
        while pending.count - consumed >= frameLength {
            inFrame.withUnsafeMutableBufferPointer { inBuf in
                pending.withUnsafeBufferPointer { src in
                    inBuf.baseAddress!.update(
                        from: src.baseAddress! + consumed, count: frameLength)
                }
            }
            _ = outFrame.withUnsafeMutableBufferPointer { outBuf in
                inFrame.withUnsafeMutableBufferPointer { inBuf in
                    df_process_frame(state, inBuf.baseAddress, outBuf.baseAddress)
                }
            }
            output.append(contentsOf: outFrame)
            consumed += frameLength
        }
        if consumed > 0 {
            pending.removeFirst(consumed)
        }
        return output
    }
}
