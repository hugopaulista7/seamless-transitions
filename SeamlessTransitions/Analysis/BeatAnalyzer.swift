import Foundation

/// Tempo + beat grid for the head and tail regions of a track.
enum BeatAnalyzer {
    /// Returns nil when no reliable beat is found (confidence < `BeatInfo.minConfidence` or < 8 beats per region).
    static func analyze(url: URL, trim: TrimInfo, regionSeconds: Double = 270) throws -> BeatInfo? {
        let s = trim.startSeconds, e = trim.endSeconds
        guard e - s >= 20 else { return nil }
        let headEnd = min(s + regionSeconds, e)
        let tailStart = max(e - regionSeconds, s)
        let single = (headEnd - tailStart) > 0.5 * regionSeconds

        // Each entry: envelope plus the file-time window whose beats are reported.
        var envs: [OnsetEnvelope] = []
        if single {
            envs = [try OnsetEnvelope.compute(url: url, from: s, to: e)]
        } else {
            envs = [try OnsetEnvelope.compute(url: url, from: s, to: headEnd),
                    try OnsetEnvelope.compute(url: url, from: tailStart, to: e)]
        }

        // Coarse tempo from averaged ACF.
        let hop = envs[0].hopSeconds
        let maxLag = 4 * TempoEstimator.lagRange(hop: hop).upperBound + 2
        var acf = [Float](repeating: 0, count: maxLag + 1)
        for env in envs {
            let a = TempoEstimator.autocorrelation(env.values, maxLag: maxLag)
            for i in 0..<acf.count { acf[i] += a[i] / Float(envs.count) }
        }
        guard let coarse = TempoEstimator.estimate(acf: acf, hop: hop) else { return nil }

        // Track each envelope twice (second pass uses the regression-refined tempo).
        var tracks: [BeatTracker.Track] = []
        for env in envs {
            guard var t = BeatTracker.track(env: env, bpm: coarse.bpm) else { return nil }
            if let t2 = BeatTracker.track(env: env, bpm: t.bpm), abs(t2.bpm / t.bpm - 1) < 0.02 { t = t2 }
            tracks.append(t)
        }

        let bpm = tracks.map { $0.bpm * Double($0.beats.count) }.reduce(0, +) / Double(tracks.reduce(0) { $0 + $1.beats.count })
        var conf = tracks.map(confidence(_:)).min()!
        // Strongly inconsistent head/tail tempo => not constant tempo.
        if tracks.count == 2, abs(tracks[0].bpm / tracks[1].bpm - 1) > 0.01 { conf *= 0.5 }
        conf = min(conf, confidenceFromACF(coarse.strength))
        guard conf >= BeatInfo.minConfidence else { return nil }

        func slice(_ t: BeatTracker.Track, from: Double, to: Double) -> ([Double], Int) {
            let first = t.beats.firstIndex { $0 >= from - 1e-9 } ?? t.beats.count
            let part = t.beats.filter { $0 >= from - 1e-9 && $0 <= to + 1e-9 }
            return (part, ((t.downbeatPhase - first) % 4 + 4) % 4)
        }
        let head: ([Double], Int), tail: ([Double], Int)
        if single {
            head = slice(tracks[0], from: s, to: headEnd)
            tail = slice(tracks[0], from: tailStart, to: e)
        } else {
            head = slice(tracks[0], from: s, to: headEnd)
            tail = slice(tracks[1], from: tailStart, to: e)
        }
        guard head.0.count >= 8, tail.0.count >= 8 else { return nil }
        return BeatInfo(bpm: bpm, confidence: conf, headBeats: head.0, tailBeats: tail.0,
                        headDownbeatIndex: head.1, tailDownbeatIndex: tail.1)
    }

    static func confidenceFromACF(_ strength: Double) -> Double { min(1, max(0, strength / 0.25)) }

    /// Combines beat regularity and beat/onset contrast.
    static func confidence(_ t: BeatTracker.Track) -> Double {
        let contrast = min(1, max(0, (t.beatStrength - 1.0) / 2.0))
        return t.regularity * contrast
    }
}
