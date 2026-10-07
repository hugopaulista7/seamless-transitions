import Foundation
import Testing
@testable import SeamlessTransitions

@Suite struct TransitionEnvelopeTests {
    private func db(_ g: Float) -> Double { 20 * log10(Double(g)) }

    @Test(arguments: [4.0, 10.0, 30.0, 60.0, 240.0])
    func exactEndpoints(t: Double) {
        let e = TransitionEnvelope(duration: t)
        #expect(e.gains(at: 0) == .init(aLow: 1, aHigh: 1, bLow: 0, bHigh: 0))
        #expect(e.gains(at: -5) == .init(aLow: 1, aHigh: 1, bLow: 0, bHigh: 0))
        #expect(e.gains(at: t) == .init(aLow: 0, aHigh: 0, bLow: 1, bHigh: 1))
        #expect(e.gains(at: t + 3) == .init(aLow: 0, aHigh: 0, bLow: 1, bHigh: 1))
    }

    @Test func stepBoundaryValuesAtSixtySeconds() {
        let e = TransitionEnvelope(duration: 60)
        #expect(e.swap == 5)
        #expect(abs(e.step1End - 0.35 * 55) < 1e-12)
        #expect(abs(e.step2End - 0.60 * 55) < 1e-12)
        #expect(abs(e.swapEnd - (33 + 5)) < 1e-12)
        // end of step 1: B high -6 dB, B low still 0, A untouched
        let g1 = e.gains(at: e.step1End)
        #expect(abs(db(g1.bHigh) + 6) < 1e-3)
        #expect(g1.bLow == 0 && g1.aLow == 1 && g1.aHigh == 1)
        let g1m = e.gains(at: e.step1End - 1e-6)
        #expect(abs(db(g1m.bHigh) + 6) < 1e-3)  // continuous
        // end of step 2: B high 0 dB, bass still not swapped
        let g2 = e.gains(at: e.step2End)
        #expect(abs(g2.bHigh - 1) < 1e-6)
        #expect(g2.bLow == 0 && g2.aLow == 1)
        // mid swap: equal power
        let gm = e.gains(at: e.step2End + e.swap / 2)
        #expect(abs(gm.aLow - Float(0.5.squareRoot())) < 1e-5)
        #expect(abs(gm.bLow - Float(0.5.squareRoot())) < 1e-5)
        #expect(gm.aHigh == 1 && gm.bHigh == 1)
        // end of swap: B low 1, A low 0, A high still 1
        let g3 = e.gains(at: e.swapEnd)
        #expect(abs(g3.bLow - 1) < 1e-6 && abs(g3.aLow) < 1e-6)
        #expect(abs(g3.aHigh - 1) < 1e-6 && g3.bHigh == 1)
        // mid step 4: A high = cos(pi/4)
        let g4 = e.gains(at: (e.swapEnd + 60) / 2)
        #expect(abs(g4.aHigh - Float(0.5.squareRoot())) < 1e-5)
        #expect(g4.aLow == 0 && g4.bLow == 1 && g4.bHigh == 1)
    }

    @Test func swapClampedForShortTransitions() {
        let e = TransitionEnvelope(duration: 10)
        #expect(abs(e.swap - 2) < 1e-12)  // 0.2 * 10, not 5
        #expect(abs(e.step1End - 0.35 * 8) < 1e-12)
        #expect(e.swapEnd < e.duration)
        let long = TransitionEnvelope(duration: 240)
        #expect(long.swap == 5)
        let tiny = TransitionEnvelope(duration: 4)
        #expect(abs(tiny.swap - 0.8) < 1e-12)
    }

    @Test(arguments: [4.0, 10.0, 60.0, 240.0])
    func monotonicAndBounded(t: Double) {
        let e = TransitionEnvelope(duration: t)
        var prev = e.gains(at: 0)
        let n = 20000
        for i in 1...n {
            let g = e.gains(at: t * Double(i) / Double(n))
            #expect(g.bLow >= prev.bLow - 1e-6 && g.bHigh >= prev.bHigh - 1e-6)
            #expect(g.aLow <= prev.aLow + 1e-6 && g.aHigh <= prev.aHigh + 1e-6)
            for v in [g.aLow, g.aHigh, g.bLow, g.bHigh] { #expect(v >= 0 && v <= 1.0000001) }
            prev = g
        }
    }

    @Test func continuousAcrossStepBoundaries() {
        let e = TransitionEnvelope(duration: 90)
        for b in [e.step1End, e.step2End, e.swapEnd] {
            let l = e.gains(at: b - 1e-7), r = e.gains(at: b + 1e-7)
            #expect(abs(l.aLow - r.aLow) < 1e-4 && abs(l.aHigh - r.aHigh) < 1e-4)
            #expect(abs(l.bLow - r.bLow) < 1e-4 && abs(l.bHigh - r.bHigh) < 1e-4)
        }
    }

    @Test func nonPositiveDurationDoesNotCrash() {
        let e = TransitionEnvelope(duration: 0)
        #expect(e.gains(at: 0).aLow == 1)
        #expect(e.gains(at: 1).bLow == 1)
    }
}
