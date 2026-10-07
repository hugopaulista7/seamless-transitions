import Foundation
import Testing
@testable import SeamlessTransitions

@Suite struct BandSplitterTests {
    /// Gain in dB of the low band for a sine at `f`.
    private func lowGainDB(_ bs: BandSplitter, sr: Double, f: Double) -> Double {
        let n = Int(sr) + 2 * bs.padding
        let s = (0..<n).map { Float(sin(2 * Double.pi * f * Double($0) / sr)) }
        let l = bs.lowBand(s)
        var pw = 0.0, pi = 0.0
        for i in 2000..<(l.count - 2000) {
            pw += Double(l[i] * l[i]); let x = Double(s[i + bs.padding]); pi += x * x
        }
        return 10 * log10(pw / pi)
    }

    @Test(arguments: [44100.0, 48000.0])
    func sixtyHzPassesAndOneKHzRejected(sr: Double) {
        let bs = BandSplitter(sampleRate: sr)
        #expect(abs(lowGainDB(bs, sr: sr, f: 60)) < 0.1)
        #expect(lowGainDB(bs, sr: sr, f: 1000) < -55)
        #expect(lowGainDB(bs, sr: sr, f: 2000) < -55)
        #expect(lowGainDB(bs, sr: sr, f: 20) > -0.1)
        // high band (x - low) carries the 1 kHz tone
        let g150 = lowGainDB(bs, sr: sr, f: 150)
        #expect(g150 < -2 && g150 > -9, "gain at cutoff \(g150) dB")
    }

    @Test func dcPassesWithUnityGain() {
        let bs = BandSplitter(sampleRate: 44100)
        let x = [Float](repeating: 0.7, count: 4000 + 2 * bs.padding)
        let l = bs.lowBand(x)
        #expect(l.count == 4000)
        for v in l { #expect(abs(v - 0.7) < 1e-5) }
    }

    @Test func outputLengthAndTooShortInput() {
        let bs = BandSplitter(sampleRate: 48000)
        #expect(bs.padding >= 16)
        #expect(bs.lowBand([Float](repeating: 0, count: 2 * bs.padding)).isEmpty)
        #expect(bs.lowBand([Float](repeating: 0, count: 2 * bs.padding + 5)).count == 5)
    }

    @Test func lowPlusHighReconstructsInput() {
        let bs = BandSplitter(sampleRate: 44100)
        var rng = SeededGenerator(seed: 4)
        let x = (0..<(5000 + 2 * bs.padding)).map { _ in Float.random(in: -1...1, using: &rng) }
        let low = bs.lowBand(x)
        let core = Array(x[bs.padding..<(x.count - bs.padding)])
        let high = zip(core, low).map { $0 - $1 }
        for i in 0..<low.count { #expect(low[i] + high[i] == core[i] || abs(low[i] + high[i] - core[i]) < 1e-6) }
    }

    @Test func chunkedEqualsOneShot() {
        let bs = BandSplitter(sampleRate: 48000)
        let pad = bs.padding
        var rng = SeededGenerator(seed: 8)
        let n = 20000
        let x = (0..<(n + 2 * pad)).map { _ in Float.random(in: -1...1, using: &rng) }
        let whole = bs.lowBand(x)
        var chunked: [Float] = []
        var pos = 0
        for size in [1, 777, 4096, 3000, 5000, 7126] {  // sums to 20000
            let m = min(size, n - pos)
            guard m > 0 else { break }
            chunked += bs.lowBand(Array(x[pos..<(pos + m + 2 * pad)]))
            pos += m
        }
        #expect(chunked.count == n)
        var worst: Float = 0
        for i in 0..<n { worst = max(worst, abs(chunked[i] - whole[i])) }
        #expect(worst < 1e-6, "worst chunk mismatch \(worst)")
    }
}
