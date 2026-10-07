@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SeamlessTransitions

/// Shared A(124 BPM @44.1k) -> B(128 BPM @48k), T ~ 30 s fixture, computed once for the suite.
final class TransitionFixture: @unchecked Sendable {
    static let t0A = 0.37, t0B = 0.52
    let dir = TempDir(name: "fixture")
    let a: ClickTrack, b: ClickTrack
    let trimA: TrimInfo, trimB: TrimInfo
    let beatsA: BeatInfo?, beatsB: BeatInfo?
    let plan: TransitionPlan
    let bakedA: [Float], bakedB: [Float]
    var urlA: URL { a.url }
    var urlB: URL { b.url }

    static let shared: TransitionFixture = {
        do { return try TransitionFixture() } catch { fatalError("fixture failed: \(error)") }
    }()

    init() throws {
        a = try TestAudio.writeClickTrack(to: dir.file("a.wav"), bpm: 124, seconds: 100, sampleRate: 44100,
                                          firstBeat: Self.t0A, kind: .tone2k, bed: 0.05)
        b = try TestAudio.writeClickTrack(to: dir.file("b.wav"), bpm: 128, seconds: 100, sampleRate: 48000,
                                          firstBeat: Self.t0B, kind: .tone2k, bed: 0.05)
        trimA = try SilenceDetector.detect(url: a.url)!
        trimB = try SilenceDetector.detect(url: b.url)!
        beatsA = try BeatAnalyzer.analyze(url: a.url, trim: trimA)
        beatsB = try BeatAnalyzer.analyze(url: b.url, trim: trimB)
        plan = TransitionPlanner.plan(a: .init(trim: trimA, beats: beatsA), b: .init(trim: trimB, beats: beatsB), requestedSeconds: 30)
        bakedA = try Self.bakeAll(url: a.url, plan: plan, side: .outgoing)
        bakedB = try Self.bakeAll(url: b.url, plan: plan, side: .incoming)
    }

    static func bakeAll(url: URL, plan: TransitionPlan, side: TransitionSide, chunkSeconds: Double = 2) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        var out: [Float] = []
        let total = plan.frames(side)
        let step = Int64(chunkSeconds * plan.sampleRate(side))
        var j: Int64 = 0
        while j < total {
            let j1 = min(j + step, total)
            out += TransitionBaker.bake(file: file, plan: plan, side: side, frames: j..<j1)[0]
            j = j1
        }
        return out
    }
}

@Suite struct TransitionPlannerBakerTests {
    let fx = TransitionFixture.shared

    @Test func analysisFindsBothTempos() throws {
        let ba = try #require(fx.beatsA), bb = try #require(fx.beatsB)
        #expect(abs(ba.bpm - 124) < 0.05)
        #expect(abs(bb.bpm - 128) < 0.05)
    }

    @Test func planIsBeatmatchedWithWholeBars() throws {
        let p = fx.plan
        #expect(p.beatMatched)
        #expect(p.outputBeats % 4 == 0)
        #expect(p.foldFactor == 1)
        #expect(abs(p.duration - 30) < 3, "T = \(p.duration)")
        let ramp = try #require(p.ramp)
        #expect(abs(ramp.totalBeats - Double(p.outputBeats)) < 1e-9)
        #expect(abs(p.duration - 120 * Double(p.outputBeats) / (ramp.bpmStart + ramp.bpmEnd)) < 1e-9)
        #expect(abs(ramp.bpmStart - 124) < 0.05 && abs(ramp.bpmEnd - 128) < 0.05)
        #expect(p.framesA == Int64((p.duration * 44100).rounded()))
        #expect(p.framesB == Int64((p.duration * 48000).rounded()))
        // A body ends where baked A starts; whole transition inside the audible region
        #expect(p.aStartFrame >= fx.trimA.startFrame)
        #expect(p.warpA.position(atFrame: p.framesA) <= Double(fx.trimA.endFrame) + 0.15 * 44100)
    }

    @Test func rampEndsHaveRateExactlyOne() {
        let p = fx.plan
        let (_, rA) = p.warpA.evaluate(frames: 0..<2)
        #expect(abs(rA[0] - 1) < 1e-6)
        let (posB, rB) = p.warpB.evaluate(frames: (p.framesB - 1)..<(p.framesB + 1))
        #expect(abs(rB[1] - 1) < 1e-6, "B end rate \(rB[1])")
        #expect(posB[1] == Double(p.bEndFrame))
        #expect(p.warpB.position(atFrame: p.framesB) == Double(p.bEndFrame))
        #expect(p.warpA.position(atFrame: 0) == Double(p.aStartFrame))
    }

    @Test func aSeamIsBitExactWithRawFile() throws {
        let p = fx.plan
        let raw = TransitionBaker.readFrames(file: try AVAudioFile(forReading: fx.urlA), start: p.aStartFrame, count: 4000)[0]
        #expect(fx.bakedA[0] == raw[0])
        // A is untouched by EQ in the first steps and its rate starts at exactly 1: stays within sinc-interpolation error
        var worst: Float = 0
        for i in 0..<64 { worst = max(worst, abs(fx.bakedA[i] - raw[i])) }
        #expect(worst < 5e-3, "first 64 samples differ by \(worst)")
    }

    @Test func bJoinMatchesRawBodyAtRateOne() throws {
        let p = fx.plan
        let fileB = try AVAudioFile(forReading: fx.urlB)
        let n = 2000
        // Bake only the final stretch (gains all 1 => no band split) and compare to the raw body that follows.
        let tail = TransitionBaker.bake(file: fileB, plan: p, side: .incoming, frames: (p.framesB - Int64(n))..<p.framesB)[0]
        let raw = TransitionBaker.readFrames(file: fileB, start: p.bEndFrame - Int64(n), count: n + 2)[0]
        var worst: Float = 0
        for i in (n - 400)..<n { worst = max(worst, abs(tail[i] - raw[i])) }
        #expect(worst < 1e-5, "B tail vs raw: \(worst)")
        // no discontinuity at the join: last baked sample vs first raw sample of the body
        #expect(abs(tail[n - 1] - raw[n - 1]) < 1e-5)
        let jump = abs(raw[n] - tail[n - 1])
        let natural = abs(raw[n] - raw[n - 1])
        #expect(jump <= natural + 1e-4)
    }

    @Test func fullyBakedBChunkedMatchesLengthAndEndpoints() {
        #expect(fx.bakedA.count == Int(fx.plan.framesA))
        #expect(fx.bakedB.count == Int(fx.plan.framesB))
        // B silent at tau = 0, A silent at the end
        #expect(fx.bakedB[0] == 0)
        #expect(abs(fx.bakedB[100]) < 1e-3)
        #expect(abs(fx.bakedA.last!) < 1e-6)
    }

    /// Mix at A's rate (B resampled 48k -> 44.1k).
    private var mix: [Float] {
        let n = fx.bakedA.count
        let ratio = 48000.0 / 44100.0
        let positions = (0..<n).map { Double($0) * ratio }
        let rb = VarispeedResampler.render(input: fx.bakedB, inputStartFrame: 0, positions: positions,
                                           rates: [Float](repeating: Float(ratio), count: n))
        return zip(fx.bakedA, rb).map { $0 + $1 }
    }

    @Test func mixHasNoGapAndNoJump() {
        let m = mix
        let sr = 44100.0
        var worstJump: Float = 0, at = 0
        for i in 1..<m.count { let d = abs(m[i] - m[i - 1]); if d > worstJump { worstJump = d; at = i } }
        #expect(worstJump < 0.3, "max jump \(worstJump) at \(Double(at) / sr) s")
        let win = Int(0.02 * sr)
        var minDB = 0.0, minAt = 0
        minDB = .infinity
        var i = 0
        while i + win <= m.count {
            var s: Float = 0
            for k in i..<(i + win) { s += m[k] * m[k] }
            let db = 20 * log10(Double((s / Float(win)).squareRoot()) + 1e-12)
            if db < minDB { minDB = db; minAt = i }
            i += win
        }
        #expect(minDB > -60, "20 ms RMS dips to \(minDB) dBFS at \(Double(minAt) / sr) s")
    }

    /// Output times at which the source click train (t0 + k*period) is played, via the position map.
    private func clickTimes(_ warp: WarpMap, click: ClickTrack, sr: Double, frames: Int64) -> [Double] {
        var res: [Double] = []
        let pEnd = warp.position(atFrame: frames) / sr
        let p0 = warp.position(atFrame: 0) / sr
        var k = 0
        while true {
            let ts = click.beatTime(k)
            k += 1
            if ts < p0 { continue }
            if ts > pEnd { break }
            var lo: Int64 = 0, hi = frames
            while hi - lo > 1 { let m = (lo + hi) / 2; if warp.position(atFrame: m) / sr < ts { lo = m } else { hi = m } }
            res.append(Double(lo) / sr)
        }
        return res
    }

    @Test func clickOnsetsCoincideThroughPositionMaps() {
        let p = fx.plan
        let ta = clickTimes(p.warpA, click: fx.a, sr: 44100, frames: p.framesA)
        let tb = clickTimes(p.warpB, click: fx.b, sr: 48000, frames: p.framesB)
        #expect(ta.count >= Int(Double(p.outputBeats) * 0.9))
        var worst = 0.0, pairs = 0
        for x in ta {
            if let y = tb.min(by: { abs($0 - x) < abs($1 - x) }), abs(y - x) < 0.1 { worst = max(worst, abs(y - x)); pairs += 1 }
        }
        #expect(pairs >= p.outputBeats - 2)
        #expect(worst <= 0.003, "ground-truth click mismatch \(worst * 1000) ms")
    }

    private func onsets(_ x: [Float], sr: Double, from: Double, to: Double) -> [Double] {
        var res: [Double] = []
        var lastHit = -1_000_000
        let gap = Int(0.1 * sr)
        for i in max(1, Int(from * sr))..<min(x.count, Int(to * sr)) where abs(x[i] - x[i - 1]) > 0.03 {
            if i - lastHit > gap { res.append(Double(i) / sr) }
            lastHit = i
        }
        return res
    }

    @Test func detectedOnsetsInBakedAudioCoincide() {
        let p = fx.plan
        let lo = p.envelope.step1End + 1, hi = p.duration - 6
        let oa = onsets(fx.bakedA, sr: 44100, from: lo, to: hi)
        let ob = onsets(fx.bakedB, sr: 48000, from: lo, to: hi)
        var worst = 0.0, pairs = 0
        for x in oa {
            if let y = ob.min(by: { abs($0 - x) < abs($1 - x) }), abs(y - x) < 0.1 { worst = max(worst, abs(y - x)); pairs += 1 }
        }
        #expect(pairs >= 20, "pairs \(pairs)")
        #expect(worst <= 0.003, "onset mismatch \(worst * 1000) ms")
    }

    @Test func tempoRampsFromAToB() {
        let p = fx.plan
        func bpm(_ o: [Double], _ from: Double, _ to: Double) -> Double {
            let s = o.filter { $0 >= from && $0 <= to }
            return s.count > 2 ? 60 * Double(s.count - 1) / (s.last! - s.first!) : 0
        }
        let head = bpm(onsets(fx.bakedA, sr: 44100, from: 0.2, to: 8), 0, 8)
        let tail = bpm(onsets(fx.bakedB, sr: 48000, from: p.duration - 8, to: p.duration - 0.2), p.duration - 8, p.duration)
        #expect(abs(head - 124) < 1.0, "A head tempo \(head)")
        #expect(abs(tail - 128) < 1.0, "B tail tempo \(tail)")
        #expect(p.masterBPM(at: 0) == p.bpmA)
        #expect(abs((p.masterBPM(at: p.duration) ?? 0) - 128) < 0.05)
        #expect(head < tail)
    }

    @Test func bandEnergyFollowsEnvelope() {
        // B must be silent through its fader-up lows (bLow == 0) until the bass swap; A bass present until swap.
        let p = fx.plan
        let e = p.envelope
        func rms(_ x: [Float], sr: Double, _ from: Double, _ to: Double) -> Double {
            let s = x[Int(from * sr)..<Int(to * sr)]
            return (s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count)).squareRoot()
        }
        let aEarly = rms(fx.bakedA, sr: 44100, 1, e.step1End)
        let bStep1 = rms(fx.bakedB, sr: 48000, 0.5, e.step1End * 0.5)
        let bStep2 = rms(fx.bakedB, sr: 48000, e.step1End, e.step2End)
        let aEnd = rms(fx.bakedA, sr: 44100, p.duration - 1, p.duration - 0.05)
        #expect(aEarly > 0.03)
        #expect(bStep1 < aEarly)         // B still ramping in
        #expect(bStep2 > bStep1)         // mids/highs up
        #expect(aEnd < aEarly * 0.1)     // A faded
    }

    // MARK: EQ-only (no beatmatch)

    @Test func tempoGapFallsBackToEQOnlyRateOne() throws {
        let d = TempDir(name: "eqonly")
        let ct = try TestAudio.writeClickTrack(to: d.file("a.wav"), bpm: 95, seconds: 80, kind: .tone2k, bed: 0.05)
        let cb = try TestAudio.writeClickTrack(to: d.file("b.wav"), bpm: 128, seconds: 80, sampleRate: 48000, kind: .tone2k, bed: 0.05)
        let ta = try #require(try SilenceDetector.detect(url: ct.url)), tb = try #require(try SilenceDetector.detect(url: cb.url))
        let ba = try BeatAnalyzer.analyze(url: ct.url, trim: ta), bb = try BeatAnalyzer.analyze(url: cb.url, trim: tb)
        #expect(abs((ba?.bpm ?? 0) - 95) < 0.05 && abs((bb?.bpm ?? 0) - 128) < 0.05)
        let p = TransitionPlanner.plan(a: .init(trim: ta, beats: ba), b: .init(trim: tb, beats: bb), requestedSeconds: 30)
        #expect(!p.beatMatched && p.ramp == nil)
        #expect(abs(p.duration - 30) < 1e-9)
        #expect(p.aStartFrame == ta.endFrame - p.framesA)
        #expect(p.bStartFrame == tb.startFrame && p.bEndFrame == tb.startFrame + p.framesB)
        let (posA, rA) = p.warpA.evaluate(frames: 0..<5000)
        let (posB, rB) = p.warpB.evaluate(frames: (p.framesB - 5000)..<p.framesB)
        #expect(rA.allSatisfy { $0 == 1 } && rB.allSatisfy { $0 == 1 })
        #expect(posA[0] == Double(p.aStartFrame) && posA[4999] == Double(p.aStartFrame + 4999))
        #expect(posB[4999] == Double(p.bEndFrame - 1))

        // First second of A (gains all 1, rate 1, integral positions) is a bit-exact copy of the raw file.
        let fileA = try AVAudioFile(forReading: ct.url)
        let bakedA = TransitionBaker.bake(file: fileA, plan: p, side: .outgoing, frames: 0..<44100)[0]
        let rawA = TransitionBaker.readFrames(file: fileA, start: p.aStartFrame, count: 44100)[0]
        #expect(bakedA == rawA)
        // B's last second joins the raw body exactly
        let fileB = try AVAudioFile(forReading: cb.url)
        let bakedB = TransitionBaker.bake(file: fileB, plan: p, side: .incoming, frames: (p.framesB - 48000)..<p.framesB)[0]
        let rawB = TransitionBaker.readFrames(file: fileB, start: p.bEndFrame - 48000, count: 48000)[0]
        #expect(bakedB == rawB)
    }

    @Test func nilBeatsPlanIsLinearAndCapped() {
        let tr = TrimInfo.untrimmed(totalFrames: 44100 * 40, sampleRate: 44100)
        let p = TransitionPlanner.plan(a: .init(trim: tr, beats: nil), b: .init(trim: tr, beats: nil), requestedSeconds: 240)
        #expect(!p.beatMatched)
        #expect(p.duration <= 20 + 1e-9)  // half of the shorter track
    }

    @Test func bIsQuietAtStartAndEmptyRangeIsEmpty() throws {
        let p = fx.plan
        let file = try AVAudioFile(forReading: fx.urlB)
        let out = TransitionBaker.bake(file: file, plan: p, side: .incoming, frames: 0..<48000)[0]
        // first second: fader barely up, bass fully cut (no 60 Hz kick or 1 kHz bed at full level)
        #expect(out.map { abs($0) }.max()! < 0.1)
        #expect(TransitionBaker.bake(file: file, plan: p, side: .incoming, frames: 5..<5)[0].isEmpty)
    }
}
