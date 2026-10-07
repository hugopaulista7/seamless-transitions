import Foundation

/// Audible region of a file after leading/trailing silence removal.
/// Frames are in the file's own sample rate (`AVAudioFile.processingFormat.sampleRate`).
struct TrimInfo: Codable, Sendable, Hashable {
    /// First audible frame (inclusive).
    var startFrame: Int64
    /// End of audible audio (exclusive).
    var endFrame: Int64
    /// Total frames in file.
    var totalFrames: Int64
    var sampleRate: Double

    var audibleFrames: Int64 { max(0, endFrame - startFrame) }
    var startSeconds: Double { Double(startFrame) / sampleRate }
    var endSeconds: Double { Double(endFrame) / sampleRate }
    var durationSeconds: Double { Double(audibleFrames) / sampleRate }

    static func untrimmed(totalFrames: Int64, sampleRate: Double) -> TrimInfo {
        TrimInfo(startFrame: 0, endFrame: totalFrames, totalFrames: totalFrames, sampleRate: sampleRate)
    }
}
