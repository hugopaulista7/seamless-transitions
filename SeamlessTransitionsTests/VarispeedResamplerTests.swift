import Foundation
import Testing
@testable import SeamlessTransitions

@Suite struct VarispeedResamplerTests {
    private func sineRef(_ f: Double, _ sr: Double, at pos: Double) -> Float { Float(sin(2 * Double.pi * f * pos / sr)) }

    @Test func integerPositionsRateOneIsBitExact() {
        var rng = SeededGenerator(seed: 1)
        let x = (0..<20000).map { _ in Float.random(in: -1...1, using: &rng) }
        let positions = (0..<10000).map { Double($0 + 1100) }  // absolute frames; input starts at 1000
        let out = VarispeedResampler.render(input: x, inputStartFrame: 1000, positions: positions,
                                            rates: [Float](repeating: 1, count: 10000))
        for j in 0..<10000 { #expect(out[j] == x[j + 100]); if out[j] != x[j + 100] { break } }
    }

    @Test func outsideInputIsZeroAtRateOne() {
        let x = [Float](repeating: 1, count: 10)
        let out = VarispeedResampler.render(input: x, inputStartFrame: 0, positions: [-3, 5, 20], rates: [1, 1, 1])
        #expect(out == [0, 1, 0])
    }

    @Test func sineAtRate105HasScaledFrequency() {
        let sr = 48000.0
        let x = TestAudio.sine(freq: 1000, amp: 1, sampleRate: sr, seconds: 4)
        let m = 48000 * 2
        let positions = (0..<m).map { 1000 + Double($0) * 1.05 }
        let y = VarispeedResampler.render(input: x, inputStartFrame: 0, positions: positions,
                                          rates: [Float](repeating: 1.05, count: m))
        // output is the original sine sampled at `positions` => exactly a 1050 Hz sine at sr.
        var e = 0.0, p = 0.0
        for j in 100..<(m - 100) {
            let r = Double(sineRef(1000, sr, at: positions[j]))
            e += (Double(y[j]) - r) * (Double(y[j]) - r); p += r * r
        }
        let errDB = 10 * log10(e / p)
        #expect(errDB < -60, "error \(errDB) dB")
        // zero-crossing frequency estimate of output (independent of the reference)
        var crossings = 0
        for j in 1..<m where y[j - 1] < 0 && y[j] >= 0 { crossings += 1 }
        let f = Double(crossings) / (Double(m) / sr)
        #expect(abs(f - 1050) < 2, "freq \(f)")
    }

    @Test func fractionalPositionRateOneInterpolatesSine() {
        let sr = 48000.0
        let x = TestAudio.sine(freq: 1000, amp: 1, sampleRate: sr, seconds: 1)
        let m = 20000
        let positions = (0..<m).map { 1000.5 + Double($0) }
        let y = VarispeedResampler.render(input: x, inputStartFrame: 0, positions: positions,
                                          rates: [Float](repeating: 1, count: m))
        var e = 0.0, p = 0.0
        for j in 100..<(m - 100) {
            let r = Double(sineRef(1000, sr, at: positions[j]))
            e += (Double(y[j]) - r) * (Double(y[j]) - r); p += r * r
        }
        #expect(10 * log10(e / p) < -60)
    }

    @Test func antiAliasAttenuatesAboveNewNyquist() {
        // 20 kHz tone read at rate 1.5 would alias to 18 kHz; the cutoff (16 kHz) must suppress it.
        let sr = 48000.0
        let x = TestAudio.sine(freq: 20000, amp: 1, sampleRate: sr, seconds: 1)
        let m = 20000
        let positions = (0..<m).map { 500 + Double($0) * 1.5 }
        let y = VarispeedResampler.render(input: x, inputStartFrame: 0, positions: positions,
                                          rates: [Float](repeating: 1.5, count: m))
        var p = 0.0
        for j in 100..<(m - 100) { p += Double(y[j]) * Double(y[j]) }
        let db = 10 * log10(p / Double(m - 200) / 0.5)
        #expect(db < -30, "alias level \(db) dB re input")
    }

    @Test func passbandToneSurvivesRateChange() {
        let sr = 48000.0
        let x = TestAudio.sine(freq: 2000, amp: 1, sampleRate: sr, seconds: 1)
        let m = 20000
        let positions = (0..<m).map { 500 + Double($0) * 0.95 }
        let y = VarispeedResampler.render(input: x, inputStartFrame: 0, positions: positions,
                                          rates: [Float](repeating: 0.95, count: m))
        let peak = y[100..<(m - 100)].map { abs($0) }.max()!
        #expect(abs(peak - 1) < 0.01)
    }
}
