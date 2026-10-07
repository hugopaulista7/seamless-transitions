import Accelerate
import Foundation

/// Global tempo from onset envelopes: weighted, harmonic-enhanced autocorrelation (coarse),
/// then robust linear regression of beat time vs beat index (fine).
enum TempoEstimator {
    static let minBPM = 60.0, maxBPM = 200.0

    /// Mean-removed autocorrelation, unbiased, normalised so acf[0] = 1. Lags 0...maxLag.
    static func autocorrelation(_ env: [Float], maxLag: Int) -> [Float] {
        let n = env.count
        var mean: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(n))
        var x = env
        var m = -mean
        vDSP_vsadd(env, 1, &m, &x, 1, vDSP_Length(n))
        let top = min(maxLag, n / 2)
        var acf = [Float](repeating: 0, count: maxLag + 1)
        for l in 0...top {
            var d: Float = 0
            vDSP_dotpr(x, 1, Array(x[l...]), 1, &d, vDSP_Length(n - l))
            acf[l] = d / Float(n - l)
        }
        if acf[0] > 0 { var inv = 1 / acf[0]; vDSP_vsmul(acf, 1, &inv, &acf, 1, vDSP_Length(acf.count)) }
        return acf
    }

    /// Lag range (frames) for the BPM limits.
    static func lagRange(hop: Double) -> ClosedRange<Int> {
        Int((60 / maxBPM / hop).rounded(.down))...Int((60 / minBPM / hop).rounded(.up))
    }

    /// Coarse tempo from (averaged) ACF. Perceptual log-Gaussian prior centred at 128 BPM.
    /// Returns bpm and ACF peak value (rough periodicity strength 0...1).
    static func estimate(acf: [Float], hop: Double) -> (bpm: Double, strength: Double)? {
        let r = lagRange(hop: hop)
        guard acf.count > 4 * r.upperBound else { return nil }
        func score(_ l: Int) -> Double {
            let bpm = 60 / (Double(l) * hop)
            let o = log2(bpm / 128) / 0.8
            return exp(-0.5 * o * o) * Double(acf[l] + 0.5 * acf[2 * l] + 0.25 * acf[4 * l])
        }
        var best = r.lowerBound, bestS = -Double.infinity
        for l in r.lowerBound...r.upperBound { let s = score(l); if s > bestS { bestS = s; best = l } }
        guard bestS > 0 else { return nil }
        var lag = Double(best)
        if best > r.lowerBound && best < r.upperBound {
            let a = Double(acf[best - 1]), b = Double(acf[best]), c = Double(acf[best + 1])
            let den = a - 2 * b + c
            if den < 0 { lag += max(-0.5, min(0.5, 0.5 * (a - c) / den)) }
        }
        return (60 / (lag * hop), Double(acf[best]))
    }

    /// Robust fit t = t0 + slope * k over beats (k = beat index from rounded successive gaps); returns BPM (60/slope).
    /// Residual rejection iterates twice with a 30 ms gate.
    static func regress(beats: [Double], period: Double) -> (bpm: Double, intercept: Double, slope: Double)? {
        guard beats.count >= 3 else { return nil }
        let t0 = beats[0]
        var idx = [Double](repeating: 0, count: beats.count)   // sequential, so coarse-period error cannot accumulate
        for i in 1..<beats.count { idx[i] = idx[i - 1] + max(1, ((beats[i] - beats[i - 1]) / period).rounded()) }
        var keep = [Bool](repeating: true, count: beats.count)
        var fit = (a: t0, b: period)
        for _ in 0..<3 {
            var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for i in 0..<beats.count where keep[i] {
                n += 1; sx += idx[i]; sy += beats[i]; sxx += idx[i] * idx[i]; sxy += idx[i] * beats[i]
            }
            let den = n * sxx - sx * sx
            guard n >= 3, den > 0 else { return nil }
            let b = (n * sxy - sx * sy) / den
            fit = ((sy - b * sx) / n, b)
            for i in 0..<beats.count { keep[i] = abs(beats[i] - (fit.a + fit.b * idx[i])) < 0.03 }
        }
        return (60 / fit.b, fit.a, fit.b)
    }
}
