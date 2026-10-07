@preconcurrency import AVFoundation
import Foundation
import os

/// DJ-style gapless player. All state lives on a private serial queue (the actor's executor); AVFoundation
/// objects never leave it. Heavy DSP (transition baking) runs in detached tasks that open their own files.
///
/// Layout: this file = state, public API, snapshot. `+Transport` = start/seek/pause/resume/stop/fades,
/// `+Transition` = commit/drive/bake pump, `+Ramps` = timer driven volume ramps.
actor PlaybackEngine {
    enum State: Sendable { case idle, playing, paused }

    /// Shortest transition worth baking; below this the plain crossfade path is used.
    static let minViableTransition = 1.5

    enum Tuning {
        static let tickInterval = 0.05
        /// Body is decoded off the engine queue in chunks of this size...
        static let bodyChunkSeconds = 5.0
        /// ...kept this far ahead of the playhead (decoded + scheduled), to ride out slow-disk stalls.
        static let bodyAheadSeconds = 15.0
        /// Body read synchronously when a voice starts, covering the first async read.
        static let bodyStartSeconds = 1.0
        static let bakeChunkSeconds = 2.0
        static let bakeAheadSeconds = 8.0
        static let startLeadSeconds = 0.4
        static let bakeLeadSeconds = 2.0
        static let lateStartLeadSeconds = 0.05
        static let commitLeadSeconds = 25.0
        static let preLimitMarginSeconds = 14.0
        static let analysisTimeout = 6.0
        static let firstFade = 0.010
        static let seekFade = 0.020
        static let pauseFade = 0.030
        static let quickFade = 1.5
        static let endFade = 0.030
    }

    /// What the UI sees, computed live or frozen while paused.
    struct Telemetry {
        var trackID: String
        var position: Double
        var duration: Double
        var inTransition: Bool
        var progress: Double
        var bpm: Double?
    }

    /// Enough information to rebuild playback from nothing (resume, device change).
    enum Anchor {
        case body(track: Track, analysis: TrackAnalysis, frame: Int64)
        case transition(plan: TransitionPlan, a: Track, aAnalysis: TrackAnalysis, b: Track, bAnalysis: TrackAnalysis, tau: Double)
    }

    /// A committed A -> B transition (A is `primary`).
    struct ActiveTransition {
        var plan: TransitionPlan
        let b: Voice
        /// A's voice-timeline sample at which output frame 0 plays (negative when rebuilt mid-transition).
        var aBase: Int64
    }

    struct Ramp {
        let id: Int
        let start: Double
        let duration: Double
        let apply: (Double) -> Void
        let completion: ((isolated PlaybackEngine) -> Void)?
    }

    // MARK: State

    let queue = DispatchSerialQueue(label: "com.hugopaulista.SeamlessTransitions.engine", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    let analyzer: TrackAnalyzer
    let clock: PlaybackClock
    let avEngine = AVAudioEngine()
    var graphReady = false
    var configObserver: NSObjectProtocol?

    var tracks: [Track] = []
    var indexByID: [String: Int] = [:]
    var order: [Int] = []
    var queuePosition = 0
    var settings = TransitionSettings()
    var unplayableIDs: Set<String> = []

    var state: State = .idle
    var primary: Voice?
    var transition: ActiveTransition?
    var fading: [Voice] = []
    var epoch = 0
    var loadingTarget: Int?
    var commitTask: Task<Void, Never>?
    var commitToken = 0

    var pausedAnchor: Anchor?
    /// Frozen UI state while paused / rebuilding (no live primary voice).
    var heldTelemetry: Telemetry?
    var lastAnchor: Anchor?
    /// Anchor of a rebuild (resume / device change) still awaiting its bakes; keeps pause/seek/resume working meanwhile.
    var rebuilding: (anchor: Anchor, epoch: Int)?
    var pauseRampID: Int?

    var tickTimer: DispatchSourceTimer?
    var rampTimer: DispatchSourceTimer?
    var ramps: [Ramp] = []
    var rampCounter = 0
    /// Uptime of the previous tick, for stall diagnostics.
    var lastTickUptime: Double?
    #if DEBUG
    /// B lag behind A (ms) measured from render timestamps; for tests/diagnostics.
    var debugAlignmentMs: Double?
    #endif

    let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SeamlessTransitions", category: "PlaybackEngine")

    init(analyzer: TrackAnalyzer, clock: PlaybackClock = PlaybackClock()) {
        self.analyzer = analyzer
        self.clock = clock
    }

    // MARK: Public API

    func setQueue(_ q: QueueSnapshot) {
        tracks = q.tracks
        order = q.order
        queuePosition = q.position
        indexByID = Dictionary(q.tracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Current voices are identified by track id, so their order position remaps by lookup. An uncommitted
        // next transition simply picks the new order's next track at commit time.
        if state != .idle, primary == nil, let t = loadingTarget, !order.indices.contains(t) { loadingTarget = nil }
        // Sticky "no transition" verdicts depended on the old order.
        primary?.noTransition = false
    }

    func setSettings(_ s: TransitionSettings) { settings = s }

    func play(orderPosition: Int) {
        guard order.indices.contains(orderPosition) else { return }
        beginLoading(position: orderPosition, step: 1)
    }

    func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .idle: play(orderPosition: min(max(queuePosition, 0), max(order.count - 1, 0)))
        }
    }

    func next() {
        let cur = loadingTarget ?? controlContext().flatMap { ctx in indexByID[ctx.track.id].flatMap { order.firstIndex(of: $0) } }
        guard let cur, order.indices.contains(cur + 1) else { return }
        beginLoading(position: cur + 1, step: 1)
    }

    func previous() {
        if let t = loadingTarget { // a load is pending: step relative to it, not to the old track
            beginLoading(position: max(t - 1, 0), step: t > 0 ? -1 : 1)
            return
        }
        guard let ctx = controlContext() else { return }
        guard let cur = indexByID[ctx.track.id].flatMap({ order.firstIndex(of: $0) }) else { return }
        if ctx.position - ctx.analysis.trim!.startSeconds > 3 || cur == 0 {
            beginLoading(position: cur, step: 1)
        } else {
            beginLoading(position: cur - 1, step: -1)
        }
    }

    func snapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        s.unplayable = Set(unplayableIDs.compactMap { indexByID[$0] })
        guard state != .idle || loadingTarget != nil else { return s }
        s.isPlaying = state == .playing
        if let p = loadingTarget, order.indices.contains(p) {
            s.currentOrderPosition = p
            s.currentTrackIndex = order[p]
        } else if let t = currentTelemetry(), let idx = indexByID[t.trackID], let pos = order.firstIndex(of: idx) {
            s.currentTrackIndex = idx
            s.currentOrderPosition = pos
            s.position = t.position
            s.duration = t.duration
            s.inTransition = t.inTransition
            s.transitionProgress = t.progress
            s.currentBPM = t.bpm
        }
        return s
    }

    // MARK: Queries

    func orderPosition(of voice: Voice) -> Int? {
        indexByID[voice.track.id].flatMap { order.firstIndex(of: $0) }
    }

    /// Voice holding the majority of the audible mix.
    func dominantVoice() -> Voice? {
        guard let a = primary else { return nil }
        if let t = transition, let tau = tau(of: t), tau / t.plan.duration > 0.5, t.b.started { return t.b }
        return a
    }

    func dominantOrderPosition() -> Int? { dominantVoice().flatMap { orderPosition(of: $0) } }

    /// Output time into the active transition (nil before A reaches the baked region or if A isn't rendering).
    func tau(of t: ActiveTransition) -> Double? {
        guard let a = primary, let played = a.playedSamples(), played >= t.aBase else { return nil }
        return Double(played - t.aBase) / a.sampleRate
    }

    func currentTelemetry() -> Telemetry? {
        if state == .paused { return heldTelemetry }
        return liveTelemetry() ?? heldTelemetry
    }

    func liveTelemetry() -> Telemetry? {
        guard let a = primary else { return nil }
        let duration = { (v: Voice) in Double(v.file.length) / v.sampleRate }
        if let t = transition, let tau = tau(of: t), t.b.started {
            let progress = min(max(tau / t.plan.duration, 0), 1)
            let dom = progress > 0.5 ? t.b : a
            let pos: Double
            if progress > 0.5 {
                pos = max(t.plan.sourcePosition(.incoming, atFrame: Int64(tau * t.plan.srB)), 0) / t.plan.srB
            } else {
                pos = (a.sourceFrame(atSample: a.playedSamples() ?? 0) ?? 0) / a.sampleRate
            }
            let bpm = t.plan.masterBPM(at: tau) ?? (dom.beats?.isReliable == true ? dom.beats?.bpm : nil)
            return Telemetry(trackID: dom.track.id, position: pos, duration: duration(dom), inTransition: tau < t.plan.duration,
                             progress: progress, bpm: bpm)
        }
        let pos = (a.sourceFrame(atSample: a.playedSamples() ?? 0) ?? Double(a.bodyNext)) / a.sampleRate
        return Telemetry(trackID: a.track.id, position: pos, duration: duration(a), inTransition: false, progress: 0,
                         bpm: a.beats?.isReliable == true ? a.beats?.bpm : nil)
    }
}

/// Resumes the continuation at most once (first of operation / timeout wins).
private final class RaceGate<T: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<T?, Never>?>(nil)
    func install(_ c: CheckedContinuation<T?, Never>) { continuation.withLock { $0 = c } }
    func finish(_ value: T?) { continuation.withLock { c in c?.resume(returning: value); c = nil } }
}

/// Runs `operation`, returning nil if it does not finish within `seconds` (the operation keeps running).
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let gate = RaceGate<T>()
    return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
        gate.install(c)
        Task { gate.finish(await operation()) }
        Task { try? await Task.sleep(for: .seconds(seconds)); gate.finish(nil) }
    }
}

import Synchronization
