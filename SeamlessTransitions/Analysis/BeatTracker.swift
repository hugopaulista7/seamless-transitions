import Accelerate
import Foundation

/// Ellis (2007) dynamic-programming beat tracker with sub-frame peak snapping and sliding-window
/// linear regression, plus low-band downbeat phase detection.
enum BeatTracker {
    struct Track: Sendable {
        /// Beat times (file seconds), complete regular grid (missed beats filled in).
        var beats: [Double]
        /// Tempo from global robust regression of the beats.
        var bpm: Double
        /// Fraction of snapped beats within 25 ms of the global grid (0...1).
        var regularity: Double
        /// Mean onset strength at beats / mean onset strength overall.
        var beatStrength: Double
        /// 0...3: beat indices i with i % 4 == phase are estimated downbeats.
        var downbeatPhase: Int
    }

    static func track(env: OnsetEnvelope, bpm: Double) -> Track? {
        let o = env.values
        let n = o.count
        let P = 60 / bpm / env.hopSeconds
        guard n > Int(4 * P), P >= 4 else { return nil }

        // --- Ellis DP ---
        let lo = max(1, Int((P / 2).rounded(.down))), hi = Int((2 * P).rounded(.up))
        let pen: [Float] = (0...hi).map { d in d < lo ? 0 : Float(-100 * pow(log(Double(d) / P), 2)) }
        var score = o
        var back = [Int](repeating: -1, count: n)
        for t in 0..<n {
            var best: Float = 0, arg = -1      // 0 => start a new chain
            let a = max(0, t - hi), b = t - lo
            if b >= a {
                for p in a...b {
                    let s = score[p] + pen[t - p]
                    if s > best { best = s; arg = p }
                }
            }
            score[t] = o[t] + best
            back[t] = arg
        }
        var endIdx = max(0, n - Int(P)), endScore = -Float.infinity
        for t in max(0, n - Int(P))..<n where score[t] > endScore { endScore = score[t]; endIdx = t }
        var frames = [Int]()
        var t = endIdx
        while t >= 0 { frames.append(t); t = back[t] }
        frames.reverse()
        guard frames.count >= 4 else { return nil }

        // --- Snap to local peaks with parabolic interpolation ---
        let rad = max(1, Int(P / 8))
        let snapped: [Double] = frames.map { f in
            var bi = f, bv = o[f]
            for g in max(1, f - rad)...min(n - 2, f + rad) where o[g] > bv { bv = o[g]; bi = g }
            var fr = Double(bi)
            if bi >= 1 && bi < n - 1 {
                let a = Double(o[bi - 1]), b = Double(o[bi]), c = Double(o[bi + 1])
                let den = a - 2 * b + c
                if den < 0 { fr += max(-0.5, min(0.5, 0.5 * (a - c) / den)) }
            }
            return env.time(ofFrame: fr)
        }
        let period = 60 / bpm
        guard let g = TempoEstimator.regress(beats: snapped, period: period) else { return nil }
        let ks = snapped.map { (($0 - g.intercept) / g.slope).rounded() }
        let reg = Double(snapped.indices.filter { abs(snapped[$0] - (g.intercept + g.slope * ks[$0])) < 0.025 }.count) / Double(snapped.count)

        // --- Sliding-window regression onto local linear grid, filling every index ---
        let k0 = Int(ks.first!), k1 = Int(ks.last!)
        let W = 8
        var beats = [Double]()
        beats.reserveCapacity(k1 - k0 + 1)
        var left = 0, right = 0
        for k in k0...k1 {
            while left < ks.count && ks[left] < Double(k - W) { left += 1 }
            while right < ks.count && ks[right] <= Double(k + W) { right += 1 }
            var a = g.intercept, b = g.slope           // fallback: global grid
            var use = Array(left..<right)
            for _ in 0..<2 where use.count >= 4 {
                var cn = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
                for i in use { let x = ks[i] - Double(k); cn += 1; sx += x; sy += snapped[i]; sxx += x * x; sxy += x * snapped[i] }
                let den = cn * sxx - sx * sx
                guard den > 0 else { break }
                b = (cn * sxy - sx * sy) / den
                a = (sy - b * sx) / cn
                use = use.filter { abs(snapped[$0] - (a + b * (ks[$0] - Double(k)))) < 0.03 }
            }
            beats.append(a)     // value of the local line at x = 0, i.e. beat k
        }

        // --- Beat strength, downbeat phase ---
        var strength = 0.0
        for t in snapped { strength += Double(o[max(0, min(n - 1, Int(env.frame(atTime: t).rounded())))]) }
        strength /= Double(snapped.count)
        var acc = [Double](repeating: 0, count: 4)
        var cnt = [Double](repeating: 0, count: 4)
        let lb = env.lowBand
        for (i, t) in beats.enumerated() {
            let f = Int(env.frame(atTime: t).rounded())
            guard f >= 1 && f < n - 1 else { continue }
            acc[i % 4] += Double(max(lb[f - 1], lb[f], lb[f + 1]))
            cnt[i % 4] += 1
        }
        var phase = 0, bestMean = -Double.infinity
        for p in 0..<4 where cnt[p] > 0 && acc[p] / cnt[p] > bestMean { bestMean = acc[p] / cnt[p]; phase = p }
        return Track(beats: beats, bpm: g.bpm, regularity: reg, beatStrength: strength, downbeatPhase: phase)
    }
}
