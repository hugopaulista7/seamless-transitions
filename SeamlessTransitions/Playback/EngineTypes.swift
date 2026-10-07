import Foundation

/// Playback queue handed from the UI to the engine. `order` holds indices into `tracks`;
/// `position` is the index into `order` of the track to play / currently playing.
struct QueueSnapshot: Sendable {
    var tracks: [Track]
    var order: [Int]
    var position: Int
}

/// Failures that are not the track's fault.
enum PlaybackError: Error {
    case engineStart(Error)
}

/// State the UI polls from the engine (~15 Hz).
struct EngineSnapshot: Sendable, Equatable {
    /// Index into `QueueSnapshot.tracks` of the dominant (audible-majority) track.
    var currentTrackIndex: Int?
    /// Index into `QueueSnapshot.order` of the dominant track.
    var currentOrderPosition: Int?
    /// Seconds in file time of the dominant track.
    var position: Double = 0
    /// Total file duration (seconds) of the dominant track.
    var duration: Double = 0
    var isPlaying: Bool = false
    var inTransition: Bool = false
    /// 0...1 while `inTransition`.
    var transitionProgress: Double = 0
    /// Effective master tempo now (nil when unknown).
    var currentBPM: Double?
    /// Track indices that could not be played (silent/unreadable), for greying out.
    var unplayable: Set<Int> = []

    static let idle = EngineSnapshot()
}

/// User-tunable settings the engine reads at transition commit time.
struct TransitionSettings: Sendable, Equatable {
    /// Total transition length in seconds (30...240).
    var seconds: Double = 60
    static let range: ClosedRange<Double> = 30...240
}
