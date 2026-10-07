import Foundation
import Testing
@testable import SeamlessTransitions

@Suite struct SilenceDetectorTests {
    /// Detector adds a 5 ms pre-roll and a 20 ms post-roll (+ up to one 10 ms window of quantisation).
    private func check(_ trim: TrimInfo?, start: Double, end: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let trim else { Issue.record("nil trim", sourceLocation: sourceLocation); return }
        #expect(abs(trim.startSeconds - start) <= 0.015, "start \(trim.startSeconds) vs \(start)", sourceLocation: sourceLocation)
        #expect(trim.endSeconds >= end - 0.015 && trim.endSeconds <= end + 0.035, "end \(trim.endSeconds) vs \(end)", sourceLocation: sourceLocation)
    }

    @Test func silenceSineSilence() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.wav")
        try TestAudio.writeSine(to: u, seconds: 3, leading: 1.5, trailing: 2)
        let trim = try SilenceDetector.detect(url: u)
        check(trim, start: 1.5, end: 4.5)
        #expect(trim?.totalFrames == Int64(6.5 * 44100))
        #expect(trim?.sampleRate == 44100)
    }

    @Test func veryQuietNoiseCountsAsSilence() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.wav")
        let sr = 44100.0
        let q = TestAudio.noise(rmsDB: -70, sampleRate: sr, seconds: 1.0)
        let q2 = TestAudio.noise(rmsDB: -70, sampleRate: sr, seconds: 1.5, seed: 2)
        let x = q + TestAudio.sine(freq: 440, sampleRate: sr, seconds: 2) + q2
        try TestAudio.write([x], sampleRate: sr, to: u)
        check(try SilenceDetector.detect(url: u), start: 1.0, end: 3.0)
    }

    @Test func allSilentIsNil() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.wav")
        try TestAudio.writeSilence(to: u, seconds: 5)
        #expect(try SilenceDetector.detect(url: u) == nil)
    }

    @Test func allVeryQuietNoiseIsNil() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.wav")
        try TestAudio.write([TestAudio.noise(rmsDB: -70, sampleRate: 44100, seconds: 3)], sampleRate: 44100, to: u)
        #expect(try SilenceDetector.detect(url: u) == nil)
    }

    @Test func fortySecondLeadingSilence() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.wav")
        try TestAudio.writeSine(to: u, sampleRate: 22050, seconds: 2, leading: 40, trailing: 1)
        check(try SilenceDetector.detect(url: u), start: 40, end: 42)
    }

    @Test func trailingSilenceLongerThanScanWindow() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.wav")
        try TestAudio.writeSine(to: u, sampleRate: 22050, seconds: 2, leading: 0.5, trailing: 75)
        check(try SilenceDetector.detect(url: u), start: 0.5, end: 2.5)
    }

    @Test func caf48kStereo() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.caf")
        try TestAudio.writeSine(to: u, sampleRate: 48000, channels: 2, seconds: 2, leading: 1, trailing: 1.25)
        let trim = try SilenceDetector.detect(url: u)
        check(trim, start: 1.0, end: 3.0)
        #expect(trim?.sampleRate == 48000)
    }

    @Test func loudOnlyInOneChannelStillDetected() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.wav")
        let sr = 44100.0
        let z = [Float](repeating: 0, count: Int(sr))
        let right = z + TestAudio.sine(freq: 300, sampleRate: sr, seconds: 1) + z
        try TestAudio.write([[Float](repeating: 0, count: right.count), right], sampleRate: sr, to: u)
        check(try SilenceDetector.detect(url: u), start: 1.0, end: 2.0)
    }

    @Test func noSilenceKeepsWholeFile() throws {
        let d = TempDir(name: "sil")
        let u = d.file("a.wav")
        try TestAudio.writeSine(to: u, seconds: 2)
        let t = try #require(try SilenceDetector.detect(url: u))
        #expect(t.startFrame == 0)
        #expect(t.endFrame == t.totalFrames)
    }
}
