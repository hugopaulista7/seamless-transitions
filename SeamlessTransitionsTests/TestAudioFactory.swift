@preconcurrency import AVFoundation
import Foundation
@testable import SeamlessTransitions

/// Per-test temp directory, removed on deinit.
final class TempDir: @unchecked Sendable {
    let url: URL

    init(name: String = "t") {
        url = FileManager.default.temporaryDirectory
            .appending(path: "SeamlessTransitionsTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appending(path: name) }
}

/// Deterministic RNG (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Description of a generated click track. Times are file time in seconds.
struct ClickTrack: Sendable {
    let url: URL
    let bpm: Double
    let sampleRate: Double
    /// Time of beat 0 (leading silence + first-beat offset).
    let firstBeat: Double
    let totalSeconds: Double
    var period: Double { 60 / bpm }
    func beatTime(_ k: Int) -> Double { firstBeat + Double(k) * period }
    /// Beat index nearest to time `t`.
    func beatIndex(near t: Double) -> Int { Int(((t - firstBeat) / period).rounded()) }
}

enum TestAudio {
    enum ClickKind: Sendable {
        /// Decaying white-noise burst (realistic, but has large sample-to-sample jumps).
        case noise
        /// Decaying 2 kHz tone burst (smooth; for jump / gap checks).
        case tone2k
    }

    // MARK: Writing

    /// Writes float32 LPCM; container follows the URL extension (wav, caf, aiff...).
    static func write(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        let n = channels[0].count
        let nch = AVAudioChannelCount(channels.count)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: nch, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                       AVNumberOfChannelsKey: Int(nch), AVLinearPCMBitDepthKey: 32,
                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 16
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        var pos = 0
        while pos < n {
            let m = min(chunk, n - pos)
            buf.frameLength = AVAudioFrameCount(m)
            for c in 0..<channels.count {
                channels[c].withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress! + pos, count: m) }
            }
            try file.write(from: buf)
            pos += m
        }
    }

    static func replicate(_ mono: [Float], channels: Int) -> [[Float]] { [[Float]](repeating: mono, count: channels) }

    static func frames(_ seconds: Double, _ sr: Double) -> Int { Int((seconds * sr).rounded()) }

    // MARK: Sample generators (mono)

    static func sine(freq: Double, amp: Float = 0.5, sampleRate: Double, seconds: Double) -> [Float] {
        (0..<frames(seconds, sampleRate)).map { amp * Float(sin(2 * Double.pi * freq * Double($0) / sampleRate)) }
    }

    /// Uniform white noise with the given RMS in dBFS.
    static func noise(rmsDB: Double, sampleRate: Double, seconds: Double, seed: UInt64 = 1) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        let peak = Float(pow(10, rmsDB / 20) * 3.0.squareRoot())
        return (0..<frames(seconds, sampleRate)).map { _ in Float.random(in: -peak...peak, using: &rng) }
    }

    /// Click track: a burst on every beat, 60 Hz kick on every 4th beat (downbeats, k % 4 == 0),
    /// optional 2 kHz-ish noise hats on the off-beats and a continuous quiet 1 kHz bed (keeps it above any silence gate).
    static func clickSamples(bpm: Double, sampleRate sr: Double, seconds: Double, firstBeat: Double = 0.37,
                             kind: ClickKind = .noise, hats: Bool = false, bed: Float = 0) -> [Float] {
        let n = frames(seconds, sr)
        var x = [Float](repeating: 0, count: n)
        var rng = SeededGenerator(seed: 12345)
        let per = 60 / bpm
        if bed > 0 {
            for i in 0..<n { x[i] += bed * Float(sin(2 * Double.pi * 1000 * Double(i) / sr)) }
        }
        var k = 0
        while true {
            let t = firstBeat + Double(k) * per
            let i0 = Int(t * sr)
            if i0 >= n { break }
            switch kind {
            case .noise:
                for j in 0..<Int(0.03 * sr) where i0 + j < n {
                    x[i0 + j] += 0.5 * Float.random(in: -1...1, using: &rng) * exp(-Float(j) / Float(0.006 * sr))
                }
            case .tone2k:
                for j in 0..<Int(0.04 * sr) where i0 + j < n {
                    x[i0 + j] += 0.4 * Float(sin(2 * Double.pi * 2000 * Double(j) / sr)) * exp(-Float(j) / Float(0.005 * sr))
                }
            }
            if k % 4 == 0 {
                for j in 0..<Int(0.2 * sr) where i0 + j < n {
                    x[i0 + j] += 0.7 * Float(sin(2 * Double.pi * 60 * Double(j) / sr)) * exp(-Float(j) / Float(0.06 * sr))
                }
            }
            if hats {
                let i1 = Int((t + per / 2) * sr)
                for j in 0..<Int(0.01 * sr) where i1 + j < n {
                    x[i1 + j] += 0.15 * Float.random(in: -1...1, using: &rng) * exp(-Float(j) / Float(0.003 * sr))
                }
            }
            k += 1
        }
        return x
    }

    /// Crude speech stand-in: pitched harmonic "syllables" of random length / pitch separated by random pauses.
    static func speechLike(sampleRate sr: Double, seconds: Double, seed: UInt64 = 7) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        let n = frames(seconds, sr)
        var x = [Float](repeating: 0, count: n)
        var t = 0.1
        while t < seconds - 0.5 {
            let len = Double.random(in: 0.06...0.35, using: &rng)
            let f0 = Double.random(in: 90...220, using: &rng)
            let i0 = Int(t * sr), cnt = Int(len * sr)
            for j in 0..<cnt where i0 + j < n {
                let u = Double(j) / Double(cnt)
                let env = Float(sin(Double.pi * u))
                var s: Float = 0
                for h in 1...8 { s += Float(sin(2 * Double.pi * f0 * Double(h) * (1 + 0.1 * u) * Double(j) / sr)) / Float(h) }
                x[i0 + j] += 0.2 * env * s
            }
            t += len + Double.random(in: 0.02...0.4, using: &rng)
        }
        return x
    }

    // MARK: File helpers

    static func writeSilence(to url: URL, sampleRate: Double = 44100, channels: Int = 1, seconds: Double) throws {
        try write(replicate([Float](repeating: 0, count: frames(seconds, sampleRate)), channels: channels), sampleRate: sampleRate, to: url)
    }

    /// leading silence + sine + trailing silence.
    static func writeSine(to url: URL, freq: Double = 440, amp: Float = 0.5, sampleRate: Double = 44100, channels: Int = 1,
                          seconds: Double, leading: Double = 0, trailing: Double = 0) throws {
        let x = [Float](repeating: 0, count: frames(leading, sampleRate))
            + sine(freq: freq, amp: amp, sampleRate: sampleRate, seconds: seconds)
            + [Float](repeating: 0, count: frames(trailing, sampleRate))
        try write(replicate(x, channels: channels), sampleRate: sampleRate, to: url)
    }

    /// Writes a click track; `seconds` is the music length, silence is added around it.
    @discardableResult
    static func writeClickTrack(to url: URL, bpm: Double, seconds: Double, sampleRate: Double = 44100, channels: Int = 1,
                                leading: Double = 0, trailing: Double = 0, firstBeat: Double = 0.37,
                                kind: ClickKind = .noise, hats: Bool = false, bed: Float = 0) throws -> ClickTrack {
        let music = clickSamples(bpm: bpm, sampleRate: sampleRate, seconds: seconds, firstBeat: firstBeat, kind: kind, hats: hats, bed: bed)
        let x = [Float](repeating: 0, count: frames(leading, sampleRate)) + music + [Float](repeating: 0, count: frames(trailing, sampleRate))
        try write(replicate(x, channels: channels), sampleRate: sampleRate, to: url)
        return ClickTrack(url: url, bpm: bpm, sampleRate: sampleRate, firstBeat: leading + firstBeat, totalSeconds: Double(x.count) / sampleRate)
    }

    static func readAll(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        return TransitionBaker.readFrames(file: file, start: 0, count: Int(file.length))
    }
}
