import Accelerate
import Foundation

/// Linear-phase FIR lowpass (Kaiser-windowed sinc, ~100 Hz transition, ~60 dB stopband, DC gain 1).
/// Non-causal: `lowBand` takes n + 2*padding samples and returns n; out[i] aligns with input[i + padding].
/// High band = x - low (exact complement). Direct-form convolution => chunked == one-shot.
struct BandSplitter: Sendable {
    let padding: Int
    private let taps: [Float]

    init(sampleRate: Double, cutoffHz: Double = 150) {
        let atten = 62.0, transitionHz = 100.0
        let dw = 2 * Double.pi * transitionHz / sampleRate
        var half = Int((((atten - 7.95) / (2.285 * dw)) / 2).rounded(.up))
        half = max(half, 16)
        padding = half
        let beta = 0.1102 * (atten - 8.7)
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
            return sum
        }
        let wc = 2 * Double.pi * cutoffHz / sampleRate
        let norm = i0(beta)
        var h = (-half...half).map { m -> Double in
            let x = Double(m)
            let s = m == 0 ? wc / Double.pi : sin(wc * x) / (Double.pi * x)
            let u = x / Double(half + 1)
            return s * i0(beta * (1 - u * u).squareRoot()) / norm
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        taps = h.map { Float($0) }
    }

    func lowBand(_ input: [Float]) -> [Float] {
        let n = input.count - 2 * padding
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        vDSP_conv(input, 1, taps, 1, &out, 1, vDSP_Length(n), vDSP_Length(taps.count))
        return out
    }
}
