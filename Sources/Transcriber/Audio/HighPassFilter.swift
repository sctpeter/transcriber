import Foundation

/// 二阶 RBJ (Robert Bristow-Johnson) biquad 高通滤波器,Q = 0.707(Butterworth,通带最平)。
/// 系数公式见 RBJ Audio EQ Cookbook。用于压低桌面震动/电源哼声等低频底噪,
/// 截止频率以下~12dB/oct 衰减,语音主能量(>200Hz)基本不受影响。
///
/// 直接型 II 转置结构(Direct Form II Transposed),数值稳定、只需两个状态变量,
/// 跨 buffer 保留状态(`process` 多次调用等价于对拼接后的连续信号做一次滤波)。
final class HighPassFilter {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0

    /// - Parameters:
    ///   - cutoffHz: 截止频率
    ///   - sampleRate: 处理时的采样率(必须与实际喂入的信号采样率一致,否则截止频率算错)
    init(cutoffHz: Float, sampleRate: Double) {
        let w0 = 2 * Float.pi * cutoffHz / Float(sampleRate)
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let q: Float = 0.70710678  // Butterworth Q,通带最平、无峰值
        let alpha = sinw0 / (2 * q)

        let a0 = 1 + alpha
        b0 = ((1 + cosw0) / 2) / a0
        b1 = -(1 + cosw0) / a0
        b2 = ((1 + cosw0) / 2) / a0
        a1 = (-2 * cosw0) / a0
        a2 = (1 - alpha) / a0
    }

    /// 原地处理,跨调用保留滤波器状态(z1/z2)
    func process(_ samples: inout [Float]) {
        for i in 0..<samples.count {
            let x = samples[i]
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            samples[i] = y
        }
    }
}
