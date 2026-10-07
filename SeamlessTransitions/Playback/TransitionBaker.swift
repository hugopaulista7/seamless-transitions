@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// Offline rendering of transition audio. Everything here is pure / thread-safe: each call opens its own
/// `AVAudioFile`, so it can run in `Task.detached` while the engine actor keeps scheduling.
enum TransitionBaker {
    enum BakeError: Error { case unreadable }

    /// Bakes output frames `frames` of `side` into per-channel float arrays.
    ///
    /// For each channel: read the source window (zero-padded outside the file), split low band in the SOURCE
    /// domain (`high = x - low`), resample both bands along the plan's position/rate map and apply the envelope:
    /// `out = gLow * R(low) + gHigh * R(high)`. When both gains are exactly 1 for the whole chunk the split is
    /// skipped (R(low) + R(high) == R(x) anyway), so A at tau = 0 is bit-identical to the raw file.
    static func bake(url: URL, plan: TransitionPlan, side: TransitionSide, frames: Range<Int64>) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        return bake(file: file, plan: plan, side: side, frames: frames)
    }

    static func bake(file: AVAudioFile, plan: TransitionPlan, side: TransitionSide, frames: Range<Int64>) -> [[Float]] {
        let channels = Int(file.processingFormat.channelCount)
        let n = Int(frames.count)
        guard n > 0 else { return [[Float]](repeating: [], count: channels) }
        let sr = plan.sampleRate(side)
        let (positions, rates) = plan.warp(side).evaluate(frames: frames)
        let env = plan.envelope

        var gLow = [Float](repeating: 0, count: n), gHigh = [Float](repeating: 0, count: n)
        var allOne = true, lowZero = true, highZero = true
        for i in 0..<n {
            let g = env.gains(at: Double(frames.lowerBound + Int64(i)) / sr)
            let (l, h) = side == .outgoing ? (g.aLow, g.aHigh) : (g.bLow, g.bHigh)
            gLow[i] = l; gHigh[i] = h
            if l != 1 || h != 1 { allOne = false }
            if l != 0 { lowZero = false }
            if h != 0 { highZero = false }
        }
        if lowZero && highZero { return [[Float]](repeating: [Float](repeating: 0, count: n), count: channels) }

        let minPos = positions.min() ?? 0, maxPos = positions.max() ?? 0
        let maxRate = Double(rates.max() ?? 1)
        let margin = Int((Double(VarispeedResampler.halfTaps) * max(1, maxRate)).rounded(.up)) + 2
        let w0 = Int64(minPos.rounded(.down)) - Int64(margin)
        let w1 = Int64(maxPos.rounded(.up)) + Int64(margin) + 1
        let splitter = allOne ? nil : BandSplitter(sampleRate: sr, cutoffHz: 150)
        let pad = splitter?.padding ?? 0
        let raw = readFrames(file: file, start: w0 - Int64(pad), count: Int(w1 - w0) + 2 * pad)

        var out = [[Float]](repeating: [], count: channels)
        for c in 0..<channels {
            let x = raw[c]
            guard let splitter else {
                out[c] = VarispeedResampler.render(input: x, inputStartFrame: w0, positions: positions, rates: rates)
                continue
            }
            let low = splitter.lowBand(x)
            let core = Array(x[pad..<(x.count - pad)])
            var high = core
            vDSP.subtract(core, low, result: &high)
            var result = [Float](repeating: 0, count: n)
            if !lowZero {
                let rl = VarispeedResampler.render(input: low, inputStartFrame: w0, positions: positions, rates: rates)
                vDSP.multiply(rl, gLow, result: &result)
            }
            if !highZero {
                let rh = VarispeedResampler.render(input: high, inputStartFrame: w0, positions: positions, rates: rates)
                var scaled = rh
                vDSP.multiply(rh, gHigh, result: &scaled)
                vDSP.add(result, scaled, result: &result)
            }
            out[c] = result
        }
        return out
    }

    /// Reads `count` frames starting at `start` (may be negative / past EOF => zeros). Per channel.
    static func readFrames(file: AVAudioFile, start: Int64, count: Int) -> [[Float]] {
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        var out = [[Float]](repeating: [Float](repeating: 0, count: max(count, 0)), count: channels)
        guard count > 0 else { return out }
        let length = file.length
        let lo = max(start, 0), hi = min(start + Int64(count), length)
        guard hi > lo, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else { return out }
        file.framePosition = lo
        var pos = lo
        while pos < hi {
            let want = AVAudioFrameCount(min(Int64(buf.frameCapacity), hi - pos))
            buf.frameLength = 0
            do { try file.read(into: buf, frameCount: want) } catch { break }
            let got = Int(buf.frameLength)
            if got == 0 { break }
            guard let data = buf.floatChannelData else { break }
            let dst = Int(pos - start)
            for c in 0..<channels {
                out[c].withUnsafeMutableBufferPointer { p in
                    p.baseAddress!.advanced(by: dst).update(from: data[c], count: got)
                }
            }
            pos += Int64(got)
        }
        return out
    }

    /// Raw frames [start, start+count) multiplied by a gain curve `gain(u)`, u in [0, 1) across the chunk.
    static func rawRamp(file: AVAudioFile, start: Int64, count: Int, gain: (Double) -> Float) -> [[Float]] {
        var x = readFrames(file: file, start: start, count: count)
        guard count > 0 else { return x }
        let g = (0..<count).map { gain(Double($0) / Double(count)) }
        for c in x.indices { vDSP.multiply(x[c], g, result: &x[c]) }
        return x
    }

    /// Converts per-channel arrays into a PCM buffer of `format`.
    static func makeBuffer(_ channels: [[Float]], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = channels.first?.count ?? 0
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let data = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<min(channels.count, Int(format.channelCount)) {
            channels[c].withUnsafeBufferPointer { data[c].update(from: $0.baseAddress!, count: n) }
        }
        return buf
    }
}
