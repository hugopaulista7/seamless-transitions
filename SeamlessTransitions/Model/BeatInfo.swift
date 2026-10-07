import Foundation

/// Tempo + beat grid for a track. All times are seconds in file time (unwarped).
struct BeatInfo: Codable, Sendable, Hashable {
    /// Global tempo estimate (BPM), constant-tempo assumption.
    var bpm: Double
    /// 0...1. Below `BeatInfo.minConfidence` the track is not beatmatched.
    var confidence: Double
    /// Beat times covering the head region (from trimmed start, ~first 4.5 min). Ascending.
    var headBeats: [Double]
    /// Beat times covering the tail region (~last 4.5 min before trimmed end). Ascending.
    var tailBeats: [Double]
    /// Index into `headBeats` of the first beat estimated to be a downbeat (bar start), 0...3.
    var headDownbeatIndex: Int
    /// Index into `tailBeats` of the first beat estimated to be a downbeat (bar start), 0...3.
    var tailDownbeatIndex: Int

    static let minConfidence: Double = 0.35

    var isReliable: Bool { confidence >= Self.minConfidence && bpm > 0 && headBeats.count >= 8 && tailBeats.count >= 8 }
}

/// Everything the analyzer knows about one track.
struct TrackAnalysis: Codable, Sendable, Hashable {
    /// nil => entire file silent / unplayable.
    var trim: TrimInfo?
    /// nil => no reliable beat (ambient, speech, failed) => EQ-only transitions.
    var beats: BeatInfo?
}
