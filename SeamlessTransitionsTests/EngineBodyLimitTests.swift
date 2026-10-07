import Testing
@testable import SeamlessTransitions

@Suite struct EngineBodyLimitTests {
    private let sr = 44100.0
    private func limit(posSec: Double, noTransition: Bool = false, hasNext: Bool = true, commitRunning: Bool = false) -> (limit: Int64, final: Bool) {
        let end = Int64(200 * sr)
        return PlaybackEngine.bodyLimit(trimStart: 0, trimEnd: end, sampleRate: sr, position: Int64(posSec * sr),
                                        preLimit: Int64(150 * sr), noTransition: noTransition, hasNext: hasNext, commitRunning: commitRunning)
    }

    @Test func earlyInTrackNotFinal() {
        let r = limit(posSec: 10)
        #expect(!r.final)
        #expect(r.limit == Int64(150 * sr))
    }

    /// Regression: seeking into the last seconds used to leave `final` false forever (silence while "playing").
    @Test func floorPastFinalLimitTakesFinalPathWhenNothingCommitted() {
        let r = limit(posSec: 197)
        #expect(r.final)
    }

    @Test func floorPastFinalLimitWaitsForRunningCommit() {
        #expect(!limit(posSec: 197, commitRunning: true).final)
    }

    @Test func noTransitionOrNoNextIsFinal() {
        #expect(limit(posSec: 10, noTransition: true).final)
        #expect(limit(posSec: 10, hasNext: false).final)
    }
}
