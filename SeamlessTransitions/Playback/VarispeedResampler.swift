import Accelerate
import Foundation

/// Band-limited (Kaiser-windowed sinc) variable-rate interpolator, single channel.
/// Kernel is tabulated once (`phases` entries per tap, linear interpolation between entries).
/// Caveat: with halfTaps = 16 the passband rolls off gently above ~0.8 * Nyquist.
enum VarispeedResampler {
    static let halfTaps: Int = 16
    private static let phases = 512
    private static let beta = 7.0

    /// P(t) = sinc(t) * kaiser(t / halfTaps), t in [-halfTaps, halfTaps], sampled every 1/phases.
    private static let table: [Float] = {
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
            return sum
        }
        let n = 2 * halfTaps * phases + 2
        let norm = i0(beta)
        return (0..<n).map { k in
            let t = Double(k) / Double(phases) - Double(halfTaps)
            let u = t / Double(halfTaps)
            guard abs(u) < 1 else { return 0 }
            let s = abs(t) < 1e-12 ? 1.0 : sin(Double.pi * t) / (Double.pi * t)
            return Float(s * i0(beta * (1 - u * u).squareRoot()) / norm)
        }
    }()

    /// `input[i]` is source frame `inputStartFrame + i`. Output j samples the source at `positions[j]`
    /// with anti-alias cutoff min(1, 1/rates[j]). Integral position + rate 1 => exact copy.
    static func render(input: [Float], inputStartFrame: Int64, positions: [Double], rates: [Float]) -> [Float] {
        let n = positions.count
        var out = [Float](repeating: 0, count: n)
        let count = input.count
        let H = Double(halfTaps), P = Double(phases)
        input.withUnsafeBufferPointer { inp in
            table.withUnsafeBufferPointer { tab in
                out.withUnsafeMutableBufferPointer { o in
                    for j in 0..<n {
                        let pos = positions[j] - Double(inputStartFrame)
                        let rate = Double(j < rates.count ? rates[j] : 1)
                        let r = pos.rounded()
                        if abs(pos - r) < 1e-9 && abs(rate - 1) < 1e-7 {
                            let i = Int(r)
                            o[j] = (i >= 0 && i < count) ? inp[i] : 0
                            continue
                        }
                        let fc = min(1.0, 1.0 / rate)
                        let reach = H / fc
                        let lo = max(0, Int((pos - reach).rounded(.up)))
                        let hi = min(count - 1, Int((pos + reach).rounded(.down)))
                        if lo > hi { continue }
                        var acc: Float = 0, wsum: Float = 0
                        for i in lo...hi {
                            let x = ((Double(i) - pos) * fc + H) * P
                            let k = Int(x)
                            let f = Float(x - Double(k))
                            let w = tab[k] + f * (tab[k + 1] - tab[k])
                            acc += w * inp[i]
                            wsum += w
                        }
                        o[j] = wsum > 1e-6 ? acc / wsum : 0
                    }
                }
            }
        }
        return out
    }
}
