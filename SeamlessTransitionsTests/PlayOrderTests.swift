import Testing
@testable import SeamlessTransitions

@Suite struct PlayOrderTests {
    @Test func sequentialStart() {
        let o = PlayOrder(count: 5, shuffled: false)
        #expect(o.order == [0, 1, 2, 3, 4])
        #expect(o.currentTrackIndex == 0)
        let o2 = PlayOrder(count: 5, shuffled: false, startingAt: 3)
        #expect(o2.currentTrackIndex == 3)
        #expect(o2.position == 3)
    }

    @Test func shuffleIsPermutationWithCurrentFirst() {
        for seed in 0..<20 {
            var rng = SeededGenerator(seed: UInt64(seed))
            let o = PlayOrder(count: 50, shuffled: true, startingAt: 17, using: &rng)
            #expect(o.order.sorted() == Array(0..<50))
            #expect(o.order.first == 17)
            #expect(o.position == 0)
            #expect(o.currentTrackIndex == 17)
        }
    }

    @Test func shuffleActuallyShuffles() {
        var rng = SeededGenerator(seed: 99)
        let o = PlayOrder(count: 50, shuffled: true, startingAt: 0, using: &rng)
        #expect(o.order != Array(0..<50))
    }

    @Test func toggleShuffleKeepsCurrentThenUnshuffleRestores() {
        var rng = SeededGenerator(seed: 5)
        var o = PlayOrder(count: 30, shuffled: false, startingAt: 12)
        o.setShuffle(true, using: &rng)
        #expect(o.currentTrackIndex == 12)
        #expect(o.order.sorted() == Array(0..<30))
        // advance a few, then unshuffle: natural order, positioned at current track
        o.position = 4
        let cur = o.currentTrackIndex
        o.setShuffle(false, using: &rng)
        #expect(o.order == Array(0..<30))
        #expect(o.currentTrackIndex == cur)
        #expect(o.position == cur)
    }

    @Test func nextAndPreviousEnds() {
        let o = PlayOrder(count: 3, shuffled: false)
        #expect(o.nextPosition(after: 0) == 1)
        #expect(o.nextPosition(after: 1) == 2)
        #expect(o.nextPosition(after: 2) == nil)
        #expect(o.previousPosition(before: 2) == 1)
        #expect(o.previousPosition(before: 0) == nil)
    }

    @Test func moveToTrackInShuffledOrder() {
        var rng = SeededGenerator(seed: 3)
        var o = PlayOrder(count: 10, shuffled: true, startingAt: 2, using: &rng)
        o.moveTo(trackIndex: 7)
        #expect(o.currentTrackIndex == 7)
        o.moveTo(trackIndex: 99)  // unknown: unchanged
        #expect(o.currentTrackIndex == 7)
    }

    @Test func emptyAndOutOfRangeStart() {
        let e = PlayOrder(count: 0, shuffled: true)
        #expect(e.currentTrackIndex == nil)
        #expect(e.nextPosition(after: 0) == nil)
        let o = PlayOrder(count: 4, shuffled: true, startingAt: 9)
        #expect(o.order.sorted() == [0, 1, 2, 3])
    }

    @Test func singleTrack() {
        var o = PlayOrder(count: 1, shuffled: true, startingAt: 0)
        #expect(o.order == [0])
        o.setShuffle(false)
        #expect(o.currentTrackIndex == 0)
        #expect(o.nextPosition(after: 0) == nil)
    }
}
