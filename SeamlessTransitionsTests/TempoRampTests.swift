import Foundation
import Testing
@testable import SeamlessTransitions

@Suite struct TempoRampTests {
    @Test func foldDoubleAndHalf() {
        let a = TempoRamp.fold(64, toward: 128)
        #expect(a.bpm == 128 && a.factor == 2)
        let b = TempoRamp.fold(140, toward: 70)
        #expect(b.bpm == 70 && b.factor == 0.5)
        let c = TempoRamp.fold(70, toward: 140)
        #expect(c.bpm == 140 && c.factor == 2)
        let d = TempoRamp.fold(128, toward: 124)
        #expect(d.bpm == 128 && d.factor == 1)
        let e = TempoRamp.fold(256, toward: 100)
        #expect(e.bpm == 128 && e.factor == 0.5)
    }

    @Test func foldInvalidInputIsIdentity() {
        #expect(TempoRamp.fold(0, toward: 120).factor == 1)
        #expect(TempoRamp.fold(120, toward: 0).bpm == 120)
    }

    @Test func masterEndpointsExactAndMonotonic() {
        let r = TempoRamp(bpmStart: 124, bpmEnd: 128, duration: 30)
        #expect(r.master(at: 0) == 124)
        #expect(r.master(at: 30) == 128)
        #expect(r.master(at: -4) == 124 && r.master(at: 99) == 128)
        #expect(abs(r.master(at: 15) - 126) < 1e-12)
        var prev = 124.0
        for i in 0...3000 {
            let m = r.master(at: 30 * Double(i) / 3000)
            #expect(m >= prev - 1e-12); prev = m
        }
        let down = TempoRamp(bpmStart: 130, bpmEnd: 120, duration: 20)
        #expect(down.master(at: 0) == 130 && down.master(at: 20) == 120)
        #expect(down.master(at: 10) < 130 && down.master(at: 10) > 120)
    }

    @Test func beatsClosedFormMatchesNumericIntegral() {
        let r = TempoRamp(bpmStart: 124, bpmEnd: 128, duration: 30.476)
        let n = 200_000
        var sum = 0.0
        let dt = r.duration / Double(n)
        for i in 0..<n { sum += r.master(at: (Double(i) + 0.5) * dt) / 60 * dt }
        #expect(abs(sum - r.beats(at: r.duration)) < 1e-6)
        #expect(abs(r.beats(at: r.duration) - r.totalBeats) < 1e-12)
        #expect(abs(r.totalBeats - r.duration * 126 / 60) < 1e-12)
        // continues at end tempo
        #expect(abs(r.beats(at: r.duration + 60) - (r.totalBeats + 128)) < 1e-9)
        #expect(r.beats(at: 0) == 0)
    }

    @Test func durationForWholeBeatsGivesIntegerBeats() {
        let t = TempoRamp.duration(forBeats: 64, bpmStart: 124, bpmEnd: 128)
        let r = TempoRamp(bpmStart: 124, bpmEnd: 128, duration: t)
        #expect(abs(t - 120.0 * 64 / 252) < 1e-12)
        #expect(abs(r.totalBeats - 64) < 1e-9)
    }

    @Test func timeOfBeatInvertsBeats() {
        let r = TempoRamp(bpmStart: 70, bpmEnd: 74, duration: 40)
        for k in stride(from: 0.0, through: r.totalBeats, by: 3) {
            #expect(abs(r.beats(at: r.time(ofBeat: k)) - k) < 1e-9)
        }
        #expect(abs(r.time(ofBeat: r.totalBeats) - 40) < 1e-6)
        #expect(r.time(ofBeat: 0) == 0)
    }

    // MARK: Planner-level tempo decisions (hand-built beat grids, no audio)

    static func beatInfo(bpm: Double, first: Double, endSeconds: Double) -> BeatInfo {
        let per = 60 / bpm
        let n = Int((endSeconds - first) / per)
        let all = (0..<n).map { first + Double($0) * per }
        return BeatInfo(bpm: bpm, confidence: 0.9, headBeats: Array(all.prefix(120)), tailBeats: Array(all.suffix(120)),
                        headDownbeatIndex: 0, tailDownbeatIndex: 0)
    }

    static func input(bpm: Double?, sr: Double = 44100, seconds: Double = 200) -> TransitionPlanner.Input {
        let total = Int64(seconds * sr)
        let trim = TrimInfo.untrimmed(totalFrames: total, sampleRate: sr)
        return .init(trim: trim, beats: bpm.map { beatInfo(bpm: $0, first: 0.5, endSeconds: seconds) })
    }

    @Test func capNoBeatmatchWhenTempoGapAboveTenPercent() {
        let p = TransitionPlanner.plan(a: Self.input(bpm: 95), b: Self.input(bpm: 128), requestedSeconds: 30)
        #expect(!p.beatMatched)
        #expect(p.ramp == nil && p.outputBeats == 0 && p.foldFactor == 1)
        #expect(abs(p.duration - 30) < 1e-9)
        #expect(p.masterBPM(at: 0) == nil)
    }

    @Test func beatmatchedWithinCap() {
        let p = TransitionPlanner.plan(a: Self.input(bpm: 120), b: Self.input(bpm: 130), requestedSeconds: 30)
        #expect(p.beatMatched)
        #expect(p.outputBeats % 4 == 0 && p.outputBeats > 0)
        #expect(p.masterBPM(at: 0) == 120 && p.masterBPM(at: p.duration) == 130)
        // M(T) == B' : 8.3% change ok, 11% not
        let over = TransitionPlanner.plan(a: Self.input(bpm: 120), b: Self.input(bpm: 134), requestedSeconds: 30)
        #expect(!over.beatMatched)
    }

    @Test func foldedHalfAndDoubleTime() {
        let half = TransitionPlanner.plan(a: Self.input(bpm: 124), b: Self.input(bpm: 62), requestedSeconds: 30)
        #expect(half.beatMatched && half.foldFactor == 2)
        #expect(half.masterBPM(at: half.duration) == 124 + 0 || abs(half.masterBPM(at: half.duration)! - 124) < 1e-9)
        let dbl = TransitionPlanner.plan(a: Self.input(bpm: 70), b: Self.input(bpm: 140), requestedSeconds: 30)
        #expect(dbl.beatMatched && dbl.foldFactor == 0.5)
        #expect(abs(dbl.masterBPM(at: dbl.duration)! - 70) < 1e-9)
        let sixtyFour = TransitionPlanner.plan(a: Self.input(bpm: 128), b: Self.input(bpm: 64), requestedSeconds: 30)
        #expect(sixtyFour.beatMatched && sixtyFour.foldFactor == 2)
    }

    @Test func unreliableOrMissingBeatsFallBackToEQOnly() {
        let p = TransitionPlanner.plan(a: Self.input(bpm: nil), b: Self.input(bpm: 128), requestedSeconds: 30)
        #expect(!p.beatMatched)
        var low = Self.input(bpm: 128)
        low.beats?.confidence = 0.1
        let q = TransitionPlanner.plan(a: Self.input(bpm: 128), b: low, requestedSeconds: 30)
        #expect(!q.beatMatched)
    }
}
