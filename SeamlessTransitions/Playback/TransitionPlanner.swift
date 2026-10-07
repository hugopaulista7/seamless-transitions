import Foundation

enum TransitionSide: Sendable { case outgoing, incoming }

/// Everything needed to bake and schedule one A -> B transition. Pure value, Sendable.
struct TransitionPlan: Sendable {
    var duration: Double
    var beatMatched: Bool
    var envelope: TransitionEnvelope
    var srA: Double
    var srB: Double
    /// Baked output frames per voice (A in A's sample rate, B in B's).
    var framesA: Int64
    var framesB: Int64
    /// A's raw body ends here; baked A starts reading the source at this (integral) frame.
    var aStartFrame: Int64
    /// B's source frame at tau = 0 (informational; B is silent there).
    var bStartFrame: Int64
    /// B's raw body resumes here (integral, rate exactly 1 at the join).
    var bEndFrame: Int64
    var warpA: WarpMap
    var warpB: WarpMap
    var ramp: TempoRamp?
    var bpmA: Double?
    var bpmB: Double?
    /// Power-of-two factor applied to B's tempo to compare with A (1 when not beatmatched).
    var foldFactor: Double
    /// Output beats in the transition (multiple of 4 when beatmatched, else 0).
    var outputBeats: Int

    func warp(_ side: TransitionSide) -> WarpMap { side == .outgoing ? warpA : warpB }
    func sampleRate(_ side: TransitionSide) -> Double { side == .outgoing ? srA : srB }
    func frames(_ side: TransitionSide) -> Int64 { side == .outgoing ? framesA : framesB }

    /// Master tempo at output time `tau` (nil when not beatmatched).
    func masterBPM(at tau: Double) -> Double? { ramp?.master(at: tau) }

    /// Source position in frames of `side` at output frame `frame`.
    func sourcePosition(_ side: TransitionSide, atFrame frame: Int64) -> Double {
        warp(side).position(atFrame: frame)
    }
}

/// Chooses transition length, start points and position maps. Pure.
enum TransitionPlanner {
    struct Input: Sendable {
        var trim: TrimInfo
        var beats: BeatInfo?
        var sampleRate: Double { trim.sampleRate }
        init(trim: TrimInfo, beats: BeatInfo?) { self.trim = trim; self.beats = beats }
    }

    static let minSeconds = 4.0
    /// Max allowed beat-to-beat source drift jump (fraction of a beat) before the grids are deemed inconsistent.
    private static let maxDriftStep = 0.2

    /// - Parameters:
    ///   - requestedSeconds: slider value.
    ///   - aEarliestStartFrame: A frames before this are already committed/scheduled; the plan must start at or after it.
    static func plan(a: Input, b: Input, requestedSeconds: Double, aEarliestStartFrame: Int64 = 0) -> TransitionPlan {
        let srA = a.sampleRate
        let la = a.trim.durationSeconds, lb = b.trim.durationSeconds
        let availA = max(0, Double(a.trim.endFrame - max(aEarliestStartFrame, a.trim.startFrame)) / srA)
        // Beat-warped A may span up to ~5% more source time than T, plus rounding to a bar: keep headroom.
        let capNoBeat = max(0.05, min(la / 2, lb / 2, availA))
        if let p = beatMatchedPlan(a: a, b: b, requested: requestedSeconds, cap: capNoBeat / 1.06 - 1, earliest: aEarliestStartFrame) {
            return p
        }
        let t0 = min(requestedSeconds, capNoBeat)
        let t = max(t0, min(minSeconds, capNoBeat))
        return linearPlan(a: a, b: b, duration: t)
    }

    // MARK: Not beatmatched

    static func linearPlan(a: Input, b: Input, duration t: Double) -> TransitionPlan {
        let srA = a.sampleRate, srB = b.sampleRate
        let nA = Int64((t * srA).rounded()), nB = Int64((t * srB).rounded())
        let aStart = a.trim.endFrame - nA
        let bStart = b.trim.startFrame
        return TransitionPlan(
            duration: t, beatMatched: false, envelope: TransitionEnvelope(duration: t), srA: srA, srB: srB,
            framesA: nA, framesB: nB, aStartFrame: aStart, bStartFrame: bStart, bEndFrame: bStart + nB,
            warpA: .linear(sampleRate: srA, startFrame: aStart), warpB: .linear(sampleRate: srB, startFrame: bStart),
            ramp: nil, bpmA: a.beats?.isReliable == true ? a.beats?.bpm : nil,
            bpmB: b.beats?.isReliable == true ? b.beats?.bpm : nil, foldFactor: 1, outputBeats: 0)
    }

    // MARK: Beatmatched

    /// Fractional-index beat time with linear interpolation inside and last-segment extrapolation outside.
    static func beatTime(_ beats: [Double], at index: Double) -> Double {
        let n = beats.count
        if index <= 0 { return beats[0] + index * (beats[1] - beats[0]) }
        if index >= Double(n - 1) {
            let k = min(4, n - 1)
            let period = (beats[n - 1] - beats[n - 1 - k]) / Double(k)
            return beats[n - 1] + (index - Double(n - 1)) * period
        }
        let i = Int(index)
        let f = index - Double(i)
        return beats[i] + f * (beats[i + 1] - beats[i])
    }

    private static func beatMatchedPlan(a: Input, b: Input, requested: Double, cap: Double, earliest: Int64) -> TransitionPlan? {
        guard let ba = a.beats, ba.isReliable, let bb = b.beats, bb.isReliable, cap >= 2 else { return nil }
        let (bpmB, factor) = TempoRamp.fold(bb.bpm, toward: ba.bpm)
        guard abs(bpmB / ba.bpm - 1) <= TempoRamp.maxTempoChange else { return nil }
        let srA = a.sampleRate, srB = b.sampleRate
        let endA = a.trim.endSeconds
        let sum = ba.bpm + bpmB

        let tcap = min(cap, TransitionSettings.range.upperBound * 2)
        let t0 = max(min(requested, tcap), min(minSeconds, tcap))
        var n = max(4, 4 * Int((t0 * sum / 120 / 4).rounded()))
        while 120 * Double(n) / sum > tcap + 0.001 && n > 4 { n -= 4 }

        // B head downbeat: first one at or after the trimmed start.
        var b0 = bb.headDownbeatIndex
        while b0 < bb.headBeats.count, bb.headBeats[b0] < b.trim.startSeconds - 0.02 { b0 += 4 }
        guard b0 < bb.headBeats.count else { return nil }

        while n >= 4 {
            defer { n -= 4 }
            // A downbeat index: largest i = tdi + 4m with beat[i + n] <= endA (+ tolerance).
            var a0 = -1
            var i = ba.tailDownbeatIndex
            while i + n <= ba.tailBeats.count - 1, ba.tailBeats[i + n] <= endA + 0.15 { a0 = i; i += 4 }
            guard a0 >= 0 else { continue }
            let fA = Int64((ba.tailBeats[a0] * srA).rounded())
            guard fA >= earliest else { continue }
            guard Double(b0) + Double(n) / factor <= Double(bb.headBeats.count - 1) + 2 else { continue }

            let t = TempoRamp.duration(forBeats: Double(n), bpmStart: ba.bpm, bpmEnd: bpmB)
            let ramp = TempoRamp(bpmStart: ba.bpm, bpmEnd: bpmB, duration: t)
            let beatTimes = (0...n).map { ramp.time(ofBeat: Double($0)) }
            let sA = (0...n).map { $0 == 0 ? Double(fA) / srA : beatTime(ba.tailBeats, at: Double(a0 + $0)) }
            let sB = (0...n).map { beatTime(bb.headBeats, at: Double(b0) + Double($0) / factor) }
            guard isConsistent(sA, period: 60 / ba.bpm), isConsistent(sB, period: 60 / bpmB) else { continue }

            let nA = Int64((t * srA).rounded()), nB = Int64((t * srB).rounded())
            let warpA = WarpMap.beatWarped(sampleRate: srA, startFrame: Double(fA), ramp: ramp, baseBPM: ba.bpm,
                                           beatTimes: beatTimes, sourceSeconds: sA)
            var warpB = WarpMap.beatWarped(sampleRate: srB, startFrame: sB[0] * srB, ramp: ramp, baseBPM: bpmB,
                                           beatTimes: beatTimes, sourceSeconds: sB)
            // Nudge B (< 0.5 sample) so it joins the raw body on an integral frame at rate exactly 1.
            let pEnd = warpB.position(atFrame: nB)
            let fEnd = pEnd.rounded()
            warpB = warpB.shifted(by: fEnd - pEnd)
            return TransitionPlan(
                duration: t, beatMatched: true, envelope: TransitionEnvelope(duration: t), srA: srA, srB: srB,
                framesA: nA, framesB: nB, aStartFrame: fA, bStartFrame: Int64(warpB.startFrame.rounded()),
                bEndFrame: Int64(fEnd), warpA: warpA, warpB: warpB, ramp: ramp, bpmA: ba.bpm, bpmB: bb.bpm,
                foldFactor: factor, outputBeats: n)
        }
        return nil
    }

    private static func isConsistent(_ s: [Double], period: Double) -> Bool {
        var prev = 0.0
        var drift = [Double](repeating: 0, count: s.count)
        for k in 0..<s.count { drift[k] = s[k] - s[0] - period * Double(k) }
        for k in 1..<s.count {
            if abs(drift[k] - prev) > maxDriftStep * period { return false }
            prev = drift[k]
        }
        return true
    }
}
