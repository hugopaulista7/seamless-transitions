@preconcurrency import AVFoundation
import Accelerate

/// Finds leading/trailing silence of an audio file.
enum SilenceDetector {
    private static let chunkFrames: AVAudioFrameCount = 8192

    /// Returns audible region, or nil if the whole file is silent.
    static func detect(url: URL, thresholdDB: Float = -50, windowMs: Double = 10, scanLimitSec: Double = 30) throws -> TrimInfo? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let total = file.length
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }
        let threshold = powf(10, thresholdDB / 20)
        let window = max(1, Int(sr * windowMs / 1000))
        let scanLimit = max(Int64(window), Int64(sr * scanLimitSec))

        /// Reads [from, to) and returns (frame offset of first loud window, end of last loud window), absolute frames.
        func scan(from: Int64, to: Int64, wantFirst: Bool, wantLast: Bool) throws -> (first: Int64?, last: Int64?) {
            file.framePosition = from
            var pos = from
            var first: Int64?
            var last: Int64?
            while pos < to {
                let n = AVAudioFrameCount(min(Int64(chunkFrames), to - pos))
                buf.frameLength = 0
                try file.read(into: buf, frameCount: n)
                let got = Int(buf.frameLength)
                if got == 0 { break }
                guard let data = buf.floatChannelData else { break }
                var off = 0
                while off < got {
                    let len = min(window, got - off)
                    var peak: Float = 0
                    for c in 0..<Int(format.channelCount) {
                        var r: Float = 0
                        vDSP_rmsqv(data[c] + off, 1, &r, vDSP_Length(len))
                        peak = max(peak, r)
                    }
                    if peak > threshold {
                        let start = pos + Int64(off)
                        if first == nil { first = start; if !wantLast { return (first, nil) } }
                        last = start + Int64(len)
                    }
                    off += len
                }
                pos += Int64(got)
            }
            return (first, last)
        }

        // Leading: scan forward until something audible.
        guard let firstLoud = try scan(from: 0, to: total, wantFirst: true, wantLast: false).first else { return nil }
        let preroll = Int64(sr * 0.005)
        let start = max(0, firstLoud - preroll)

        // Trailing: tail region first, then backward blocks.
        var blockEnd = total
        var lastLoud: Int64?
        while lastLoud == nil && blockEnd > 0 {
            let blockStart = max(0, blockEnd - scanLimit)
            lastLoud = try scan(from: blockStart, to: blockEnd, wantFirst: false, wantLast: true).last
            blockEnd = blockStart
        }
        guard let lastLoud else { return nil }
        let end = min(total, lastLoud + Int64(sr * 0.020))
        guard end > start else { return nil }
        return TrimInfo(startFrame: start, endFrame: end, totalFrames: total, sampleRate: sr)
    }
}
