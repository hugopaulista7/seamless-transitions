import Accelerate
import AVFoundation
import Foundation

/// Spectral-flux onset strength + low-band (<150 Hz) amplitude envelope of a file region.
struct OnsetEnvelope: Sendable {
    /// Onset strength per frame (local-mean removed, >= 0, unit std).
    var values: [Float]
    /// RMS-like amplitude of the <150 Hz band per frame (for downbeat accents).
    var lowBand: [Float]
    var hopSeconds: Double
    /// File time (s) of the first analysed sample.
    var startTime: Double
    /// Seconds from region start to the reference point of frame 0 (window centre, latency-calibrated).
    var frame0Offset: Double

    /// File time of (fractional) frame index f.
    func time(ofFrame f: Double) -> Double { startTime + frame0Offset + f * hopSeconds }
    /// Fractional frame index for file time t.
    func frame(atTime t: Double) -> Double { (t - startTime - frame0Offset) / hopSeconds }

    enum Failure: Error { case emptyRegion, bufferFailure }

    static let fftSize = 1024
    /// Empirical onset-detection lead (samples @ decimated rate) removed from frame time.
    static let latencySamples: Double = -200

    static func compute(url: URL, from startSec: Double, to endSec: Double) throws -> OnsetEnvelope {
        let (mono, sr) = try readMono(url: url, from: startSec, to: endSec)
        return try analyze(mono: mono, sampleRate: sr, startTime: startSec)
    }

    /// Mono mixdown decimated (box filter) by round(sr/22050).
    static func readMono(url: URL, from startSec: Double, to endSec: Double) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let s0 = max(0, min(file.length, Int64((startSec * sr).rounded())))
        let s1 = max(s0, min(file.length, Int64((endSec * sr).rounded())))
        guard s1 > s0 else { throw Failure.emptyRegion }
        let factor = max(1, Int((sr / 22050).rounded()))
        let chunk = 65536 - 65536 % factor
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else { throw Failure.bufferFailure }
        file.framePosition = s0
        var mono = [Float]()
        mono.reserveCapacity(Int(s1 - s0) / factor + 1)
        var mix = [Float](repeating: 0, count: chunk)
        var dec = [Float](repeating: 0, count: chunk / factor + 1)
        let boxcar = [Float](repeating: 1 / Float(factor), count: factor)
        let ch = Int(fmt.channelCount)
        var remaining = s1 - s0
        while remaining > 0 {
            try file.read(into: buf, frameCount: AVAudioFrameCount(min(Int64(chunk), remaining)))
            let got = Int(buf.frameLength)
            if got == 0 { break }
            remaining -= Int64(got)
            guard let data = buf.floatChannelData else { throw Failure.bufferFailure }
            mix.withUnsafeMutableBufferPointer { m in
                m.baseAddress!.update(from: data[0], count: got)
                for c in 1..<max(ch, 1) { vDSP_vadd(m.baseAddress!, 1, data[c], 1, m.baseAddress!, 1, vDSP_Length(got)) }
                if ch > 1 { var s = 1 / Float(ch); vDSP_vsmul(m.baseAddress!, 1, &s, m.baseAddress!, 1, vDSP_Length(got)) }
            }
            if factor == 1 {
                mono.append(contentsOf: mix[0..<got])
            } else {
                let outN = got / factor
                if outN > 0 {
                    vDSP_desamp(mix, vDSP_Stride(factor), boxcar, &dec, vDSP_Length(outN), vDSP_Length(factor))
                    mono.append(contentsOf: dec[0..<outN])
                }
            }
        }
        return (mono, sr / Double(factor))
    }

    static func analyze(mono x: [Float], sampleRate sr: Double, startTime: Double) throws -> OnsetEnvelope {
        let N = fftSize, half = N / 2
        let hop = Int((0.0116 * sr).rounded())
        guard x.count >= N + 32 * hop else { throw Failure.emptyRegion }
        let frames = (x.count - N) / hop + 1
        guard let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { throw Failure.bufferFailure }
        defer { vDSP_destroy_fftsetup(setup) }

        var hann = [Float](repeating: 0, count: N)
        vDSP_hann_window(&hann, vDSP_Length(N), Int32(vDSP_HANN_NORM))
        var wbuf = [Float](repeating: 0, count: N)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mag2 = [Float](repeating: 0, count: half), mag = [Float](repeating: 0, count: half)
        var logm = [Float](repeating: 0, count: half), prev = [Float](repeating: 0, count: half)
        var diff = [Float](repeating: 0, count: half)
        let lowBins = max(2, Int(150 * Double(N) / sr))     // bins 1..<lowBins
        let fluxBins = min(half, Int(5500 * Double(N) / sr))
        let lowEmph = min(lowBins * 2, fluxBins)
        var flux = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var cnt = Int32(half)
        var scale: Float = 2 * 2 / Float(N)    // ~ amplitude units * 1000/... see log1p below
        var thresh: Float = 0

        for k in 0..<frames {
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + k * hop, 1, hann, 1, &wbuf, 1, vDSP_Length(N)) }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                wbuf.withUnsafeBufferPointer { $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) } }
                vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                ip[0] = 0
                vDSP_zvmags(&split, 1, &mag2, 1, vDSP_Length(half))
            } }
            vvsqrtf(&mag, mag2, &cnt)
            var lowSum: Float = 0
            vDSP_sve(Array(mag2[1..<lowBins]), 1, &lowSum, vDSP_Length(lowBins - 1))
            low[k] = lowSum.squareRoot() * (2 / Float(N)) * 2   // ~ sinusoid amplitude units
            vDSP_vsmul(mag, 1, &scale, &mag, 1, vDSP_Length(half))   // mag * 4/N ~ amplitude
            var c: Float = 1000
            vDSP_vsmul(mag, 1, &c, &mag, 1, vDSP_Length(half))
            vvlog1pf(&logm, mag, &cnt)
            if k > 0 {
                vDSP_vsub(prev, 1, logm, 1, &diff, 1, vDSP_Length(half))
                vDSP_vthres(diff, 1, &thresh, &diff, 1, vDSP_Length(half))
                var s: Float = 0, sl: Float = 0
                vDSP_sve(Array(diff[1..<fluxBins]), 1, &s, vDSP_Length(fluxBins - 1))
                vDSP_sve(Array(diff[1..<lowEmph]), 1, &sl, vDSP_Length(lowEmph - 1))
                flux[k] = s + 2 * sl
            }
            swap(&prev, &logm)
        }
        flux[0] = 0

        // Remove ~1 s local mean, rectify, normalise to unit std.
        let w = max(3, Int(1.0 / (Double(hop) / sr))) | 1
        var cum = [Double](repeating: 0, count: frames + 1)
        for i in 0..<frames { cum[i + 1] = cum[i] + Double(flux[i]) }
        var env = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let a = max(0, i - w / 2), b = min(frames, i + w / 2 + 1)
            let m = (cum[b] - cum[a]) / Double(b - a)
            env[i] = max(0, flux[i] - Float(m))
        }
        var rms: Float = 0
        vDSP_rmsqv(env, 1, &rms, vDSP_Length(frames))
        if rms > 1e-9 { var inv = 1 / rms; vDSP_vsmul(env, 1, &inv, &env, 1, vDSP_Length(frames)) }

        let hopSec = Double(hop) / sr
        return OnsetEnvelope(values: env, lowBand: low, hopSeconds: hopSec, startTime: startTime,
                             frame0Offset: (Double(half) - latencySamples) / sr)
    }
}
