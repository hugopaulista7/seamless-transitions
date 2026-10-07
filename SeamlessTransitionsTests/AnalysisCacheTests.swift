import Foundation
import Testing
@testable import SeamlessTransitions

@Suite struct AnalysisCacheTests {
    private let sample = TrackAnalysis(
        trim: TrimInfo(startFrame: 100, endFrame: 5000, totalFrames: 6000, sampleRate: 44100),
        beats: BeatInfo(bpm: 123.97, confidence: 0.8, headBeats: (0..<10).map { 0.5 + Double($0) * 0.484 },
                        tailBeats: (0..<10).map { 90 + Double($0) * 0.484 }, headDownbeatIndex: 2, tailDownbeatIndex: 1))

    @Test func missingFileGivesNil() async {
        let d = TempDir(name: "cache")
        let c = AnalysisCache(fileURL: d.file("none/analysis.json"))
        #expect(await c.get("k") == nil)
    }

    /// Beat grids round-trip through f32 sidecars: equal within 0.1 ms.
    private func expectClose(_ a: TrackAnalysis?, _ b: TrackAnalysis) {
        #expect(a?.trim == b.trim)
        #expect(a?.beats?.bpm == b.beats?.bpm)
        #expect(a?.beats?.headDownbeatIndex == b.beats?.headDownbeatIndex)
        #expect(a?.beats?.tailDownbeatIndex == b.beats?.tailDownbeatIndex)
        for (x, y) in zip(a?.beats?.headBeats ?? [], b.beats?.headBeats ?? []) { #expect(abs(x - y) < 1e-4) }
        for (x, y) in zip(a?.beats?.tailBeats ?? [], b.beats?.tailBeats ?? []) { #expect(abs(x - y) < 1e-4) }
        #expect(a?.beats?.headBeats.count == b.beats?.headBeats.count)
        #expect(a?.beats?.tailBeats.count == b.beats?.tailBeats.count)
    }

    @Test func inMemorySetGet() async {
        let d = TempDir(name: "cache")
        let c = AnalysisCache(fileURL: d.file("analysis.json"))
        await c.set("k", sample)
        expectClose(await c.get("k"), sample)
        #expect(await c.get("other") == nil)
    }

    @Test func persistsToDiskAndReloads() async throws {
        let d = TempDir(name: "cache")
        let file = d.file("sub/analysis.json")
        let c = AnalysisCache(fileURL: file)
        await c.set("a", sample)
        await c.set("b", TrackAnalysis(trim: nil, beats: nil))
        // Throttled save fires after ~2 s.
        var waited = 0.0
        while !FileManager.default.fileExists(atPath: file.path) && waited < 6 {
            try await Task.sleep(for: .milliseconds(250)); waited += 0.25
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        let c2 = AnalysisCache(fileURL: file)
        expectClose(await c2.get("a"), sample)
        #expect(await c2.get("b") == TrackAnalysis(trim: nil, beats: nil))
    }

    @Test func corruptFileIsIgnored() async throws {
        let d = TempDir(name: "cache")
        let file = d.file("analysis.json")
        try Data("not json".utf8).write(to: file)
        let c = AnalysisCache(fileURL: file)
        #expect(await c.get("k") == nil)
    }

    @Test func keyChangesWhenFileChanges() throws {
        let d = TempDir(name: "cache")
        let u = d.file("a.wav")
        try TestAudio.writeSine(to: u, seconds: 1)
        let track = Track(url: u, root: d.url)
        let k1 = AnalysisCache.key(for: track)
        #expect(k1 == AnalysisCache.key(for: track))
        #expect(k1.contains(track.id))
        #expect(k1.hasSuffix("|v\(AnalysisCache.algorithmVersion)"))
        try TestAudio.writeSine(to: u, seconds: 2)
        #expect(AnalysisCache.key(for: Track(url: u, root: d.url)) != k1)
    }

    /// Regression: Track.url caches resource values (fileSize/mtime) after the first lookup, so the same Track instance
    /// keeps producing a stale key after the file changes on disk (AnalysisCache.swift:33).
    func keyChangesForSameTrackInstanceWhenFileChanges() throws {
        let d = TempDir(name: "cache")
        let u = d.file("a.wav")
        try TestAudio.writeSine(to: u, seconds: 1)
        let track = Track(url: u, root: d.url)
        let k1 = AnalysisCache.key(for: track)
        try TestAudio.writeSine(to: u, seconds: 2)
        #expect(AnalysisCache.key(for: track) != k1)
    }

    @Test func flushPersistsImmediatelyAndSidecarIsLazy() async throws {
        let d = TempDir(name: "cache")
        let file = d.file("analysis-index.json")
        let c = AnalysisCache(fileURL: file)
        await c.set("a", sample)
        await c.flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Index holds no beat times; they live in a sidecar.
        let index = try String(contentsOf: file, encoding: .utf8)
        #expect(!index.contains("headBeats"))
        let sums = await AnalysisCache(fileURL: file).summaries(for: ["a", "zz"])
        #expect(sums[0] == AnalysisCache.Summary(playable: true, reliableBPM: 123.97))
        #expect(sums[1] == nil)
    }

    @Test func missingSidecarIsAMiss() async throws {
        let d = TempDir(name: "cache")
        let file = d.file("analysis.json")
        let c = AnalysisCache(fileURL: file)
        await c.set("a", sample)
        await c.flush()
        let beats = d.file("beats")
        for f in try FileManager.default.contentsOfDirectory(atPath: beats.path) { try FileManager.default.removeItem(at: beats.appending(path: f)) }
        #expect(await AnalysisCache(fileURL: file).get("a") == nil)
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(sample)
        #expect(try JSONDecoder().decode(TrackAnalysis.self, from: data) == sample)
    }
}
