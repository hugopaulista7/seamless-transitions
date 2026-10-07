import Foundation

/// Master tempo ramp M(tau): smoothstep from `bpmStart` (A) to `bpmEnd` (B, folded) over `duration`.
///
/// Closed forms (u = tau / T, s(u) = 3u^2 - 2u^3):
///   M(tau)      = A (1 - s) + B s
///   beats(tau)  = (A tau + (B - A) T (u^3 - u^4 / 2)) / 60          (integral of M / 60)
///   beats(T)    = T (A + B) / 120   =>   T = 120 N / (A + B) for N whole output beats.
struct TempoRamp: Sendable, Equatable {
    let bpmStart: Double
    let bpmEnd: Double
    let duration: Double

    /// Largest relative tempo change that is still beatmatched.
    static let maxTempoChange = 0.10

    var totalBeats: Double { duration * (bpmStart + bpmEnd) / 120 }

    static func duration(forBeats n: Double, bpmStart: Double, bpmEnd: Double) -> Double {
        120 * n / (bpmStart + bpmEnd)
    }

    private func smooth(_ t: Double) -> Double {
        let u = min(max(t / duration, 0), 1)
        return u * u * (3 - 2 * u)
    }

    /// Master BPM at output time `t` (clamped to the ramp). Exactly `bpmStart` at 0 and `bpmEnd` at T.
    func master(at t: Double) -> Double {
        let s = smooth(t)
        return bpmStart * (1 - s) + bpmEnd * s
    }

    /// Output beats elapsed at time `t` (continues at `bpmEnd` past T).
    func beats(at t: Double) -> Double {
        if t <= 0 { return bpmStart * t / 60 }
        if t >= duration { return totalBeats + bpmEnd * (t - duration) / 60 }
        let u = t / duration
        return (bpmStart * t + (bpmEnd - bpmStart) * duration * (u * u * u - u * u * u * u / 2)) / 60
    }

    /// Inverse of `beats(at:)` (monotonic, bisection).
    func time(ofBeat k: Double) -> Double {
        if k <= 0 { return 60 * k / bpmStart }
        if k >= totalBeats { return duration + (k - totalBeats) * 60 / bpmEnd }
        var lo = 0.0, hi = duration
        for _ in 0..<100 {
            let mid = (lo + hi) / 2
            if beats(at: mid) < k { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Folds `bpm` by powers of two so it lands nearest `reference` (log-distance).
    /// `factor` is the multiplier applied (0.5 => B is played as double-time reference, etc.).
    static func fold(_ bpm: Double, toward reference: Double) -> (bpm: Double, factor: Double) {
        guard bpm > 0, reference > 0 else { return (bpm, 1) }
        let k = log2(reference / bpm).rounded()
        let f = pow(2, k)
        return (bpm * f, f)
    }
}

/// Maps output frames (in a track's own sample rate) to fractional source frames, plus local playback rate.
///
/// Beat-warped design: pos(tau) = start + sr * (S(tau) + d(tau))
///  - S(tau) = 60 * beats(tau) / baseBPM : ideal constant-tempo advance driven by the master ramp
///    (rate M/baseBPM, exactly 1 at A's start and at B's end).
///  - d(tau): C1 cubic Hermite through the per-beat drift d_k = (true source beat time - ideal) sampled at the
///    output beat times tau_k, with zero slope at both ends. So every output beat lands exactly on the track's
///    real beat (locks A and B together whole transition), rates are continuous, and the ends keep rate exactly 1.
/// Linear maps (not beatmatched): pos = start + frame, rate 1.
struct WarpMap: Sendable {
    struct BeatWarp: Sendable {
        let ramp: TempoRamp
        let baseBPM: Double
        /// tau_k: output time of output beat k, k = 0...N.
        let beatTimes: [Double]
        /// d_k in source seconds.
        let drift: [Double]
        /// Hermite slopes (source seconds per output second); zero at both ends.
        let slopes: [Double]
    }

    let sampleRate: Double
    /// Source frame at tau = 0.
    let startFrame: Double
    let beat: BeatWarp?

    static func linear(sampleRate: Double, startFrame: Int64) -> WarpMap {
        WarpMap(sampleRate: sampleRate, startFrame: Double(startFrame), beat: nil)
    }

    static func beatWarped(sampleRate: Double, startFrame: Double, ramp: TempoRamp, baseBPM: Double,
                           beatTimes: [Double], sourceSeconds: [Double]) -> WarpMap {
        let s0 = sourceSeconds[0]
        let n = beatTimes.count
        let drift = (0..<n).map { k in sourceSeconds[k] - (s0 + 60 * Double(k) / baseBPM) }
        var slopes = [Double](repeating: 0, count: n)
        if n > 2 {
            for k in 1..<(n - 1) { slopes[k] = (drift[k + 1] - drift[k - 1]) / (beatTimes[k + 1] - beatTimes[k - 1]) }
        }
        return WarpMap(sampleRate: sampleRate, startFrame: startFrame,
                       beat: BeatWarp(ramp: ramp, baseBPM: baseBPM, beatTimes: beatTimes, drift: drift, slopes: slopes))
    }

    /// Same map shifted by `frames` source frames.
    func shifted(by frames: Double) -> WarpMap {
        WarpMap(sampleRate: sampleRate, startFrame: startFrame + frames, beat: beat)
    }

    func position(atFrame frame: Int64) -> Double {
        var seg = 0
        return sample(frame: frame, segment: &seg).position
    }

    /// Positions (source frames) and instantaneous rates for output frames in `frames`.
    func evaluate(frames: Range<Int64>) -> (positions: [Double], rates: [Float]) {
        let n = Int(frames.count)
        var pos = [Double](repeating: 0, count: n)
        var rates = [Float](repeating: 1, count: n)
        var seg = 0
        for i in 0..<n {
            let s = sample(frame: frames.lowerBound + Int64(i), segment: &seg)
            pos[i] = s.position
            rates[i] = Float(s.rate)
        }
        return (pos, rates)
    }

    private func sample(frame: Int64, segment seg: inout Int) -> (position: Double, rate: Double) {
        guard let b = beat else { return (startFrame + Double(frame), 1) }
        let tau = Double(frame) / sampleRate
        let n = b.beatTimes.count
        var d = b.drift[n - 1], dd = 0.0
        if tau < b.beatTimes[n - 1] {
            if seg >= n - 1 || tau < b.beatTimes[seg] || tau >= b.beatTimes[seg + 1] {
                var lo = 0, hi = n - 1
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if b.beatTimes[mid] <= tau { lo = mid } else { hi = mid }
                }
                seg = lo
            }
            let t0 = b.beatTimes[seg], t1 = b.beatTimes[seg + 1]
            let h = t1 - t0
            let s = (tau - t0) / h
            let s2 = s * s, s3 = s2 * s
            let p0 = b.drift[seg], p1 = b.drift[seg + 1]
            let m0 = b.slopes[seg] * h, m1 = b.slopes[seg + 1] * h
            d = (2 * s3 - 3 * s2 + 1) * p0 + (s3 - 2 * s2 + s) * m0 + (-2 * s3 + 3 * s2) * p1 + (s3 - s2) * m1
            dd = ((6 * s2 - 6 * s) * p0 + (3 * s2 - 4 * s + 1) * m0 + (-6 * s2 + 6 * s) * p1 + (3 * s2 - 2 * s) * m1) / h
        }
        let ideal = 60 * b.ramp.beats(at: tau) / b.baseBPM
        let rate = b.ramp.master(at: tau) / b.baseBPM + dd
        return (startFrame + sampleRate * (ideal + d), rate)
    }
}
