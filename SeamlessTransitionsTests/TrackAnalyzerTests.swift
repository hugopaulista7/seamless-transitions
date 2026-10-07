import Foundation
import Testing
@testable import SeamlessTransitions

@Suite struct TrackAnalyzerTests {
    @Test func unreadableFileIsTransientAndNotCached() async {
        let d = TempDir(name: "an")
        let bogus = d.file("nope.wav")
        try? Data("not audio".utf8).write(to: bogus)
        let cache = AnalysisCache(fileURL: d.file("idx.json"))
        let analyzer = TrackAnalyzer(cache: cache)
        let track = Track(url: bogus, root: d.url)
        let r = await analyzer.analysis(for: track)
        #expect(r.trim == nil)
        #expect(await analyzer.cached(track) == nil)
    }

    @Test func silentFileIsCachedAsSilent() async throws {
        let d = TempDir(name: "an")
        let u = d.file("silent.wav")
        try TestAudio.writeSilence(to: u, seconds: 2)
        let analyzer = TrackAnalyzer(cache: AnalysisCache(fileURL: d.file("idx.json")))
        let track = Track(url: u, root: d.url)
        #expect(await analyzer.analysis(for: track).trim == nil)
        let cached = await analyzer.cached(track)
        #expect(cached != nil && cached?.trim == nil)
    }

    /// A high priority request must not wait behind a long queue of background work.
    @Test func highPriorityJumpsBackgroundQueue() async throws {
        let d = TempDir(name: "an")
        var tracks: [Track] = []
        for i in 0..<40 {
            let u = d.file("t\(i).wav")
            try TestAudio.writeSine(to: u, seconds: 1)
            tracks.append(Track(url: u, root: d.url))
        }
        let analyzer = TrackAnalyzer(cache: AnalysisCache(fileURL: d.file("idx.json")))
        await analyzer.prefetch(tracks, priority: .utility)
        let last = tracks[39]
        let started = ContinuousClock.now
        let r = await analyzer.analysis(for: last, priority: .userInitiated)
        let took = ContinuousClock.now - started
        #expect(r.trim != nil)
        // Finishing before most of the queue: the others (2 at a time) would need many x this.
        #expect(took < .seconds(5))
        await analyzer.cancelBackground()
    }

    @Test func cancelBackgroundDropsQueuedWork() async throws {
        let d = TempDir(name: "an")
        var tracks: [Track] = []
        for i in 0..<20 {
            let u = d.file("t\(i).wav")
            try TestAudio.writeSine(to: u, seconds: 1)
            tracks.append(Track(url: u, root: d.url))
        }
        let analyzer = TrackAnalyzer(cache: AnalysisCache(fileURL: d.file("idx.json")))
        await analyzer.prefetch(tracks, priority: .utility)
        await analyzer.cancelBackground()
        try await Task.sleep(for: .seconds(1.5))
        var done = 0
        for t in tracks where await analyzer.cached(t) != nil { done += 1 }
        #expect(done <= 4) // only the (<= 2) already running computes finish, plus slack
    }
}
