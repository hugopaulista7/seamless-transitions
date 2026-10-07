@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// One track playing through its own `AVAudioPlayerNode`, connected to the main mixer in the
/// file's processing format (the mixer resamples). Confined to the engine actor (not Sendable).
///
/// The voice timeline is in frames at the file's sample rate, counted from the node's `play`. Every scheduled
/// piece is recorded as an `Item`, so a played-sample count maps back to a source position.
final class Voice {
    enum Kind {
        /// Raw file segment starting at source frame `src` (1 voice frame == 1 source frame).
        case body(src: Int64)
        /// Baked transition audio: voice frame i maps to output frame `firstOut + i` of `plan`'s `side`.
        case baked(side: TransitionSide, plan: TransitionPlan, firstOut: Int64)
    }

    struct Item {
        var start: Int64
        var length: Int64
        var kind: Kind
        var end: Int64 { start + length }
    }

    /// Transition bake bookkeeping for this voice.
    struct BakeJob {
        var plan: TransitionPlan
        var side: TransitionSide
        /// Output frames baked in total (exclusive end).
        var total: Int64
        /// Output frames already baked (scheduled or ready); also the next frame to request.
        var doneThrough: Int64
        /// Voice-timeline sample at which output frame 0 plays (may be negative when rebuilt mid-transition).
        var baseSample: Int64
        var inFlight = false
    }

    struct ReadyChunk {
        var buffer: AVAudioPCMBuffer
        var firstOut: Int64
    }

    /// Raw body audio decoded ahead of scheduling, starting at source frame `src`.
    struct BodyChunk {
        var buffer: AVAudioPCMBuffer
        var src: Int64
        var end: Int64 { src + Int64(buffer.frameLength) }
    }

    /// File handle owned by the background body reader (one read in flight at a time, never touched elsewhere).
    final class BodyReader: @unchecked Sendable {
        let url: URL
        private var file: AVAudioFile?
        init(url: URL) { self.url = url }
        func read(start: Int64, count: Int) -> [[Float]]? {
            if file == nil { file = try? AVAudioFile(forReading: url) }
            guard let file else { return nil }
            return TransitionBaker.readFrames(file: file, start: start, count: count)
        }
    }

    private static let counter = Mutex(0)
    let id: Int
    let track: Track
    let node = AVAudioPlayerNode()
    /// Handle for synchronous reads on the engine queue (fades, start chunk); the body reader has its own.
    let file: AVAudioFile
    let format: AVAudioFormat
    let sampleRate: Double
    var trim: TrimInfo
    var beats: BeatInfo?

    var items: [Item] = []
    /// Voice-timeline end of everything scheduled.
    var scheduledEnd: Int64 = 0
    var bodyNext: Int64
    var bodyLimit: Int64
    var bodyEnabled = true
    /// True once the final fade-out piece is scheduled (nothing else will ever be).
    var finished = false
    var tailFadeEnabled = false
    /// Set once no transition can be committed (nothing playable next, or too little track left): the voice
    /// ends with a plain fade and the engine starts the next track itself.
    var noTransition = false
    /// Trim came from the untrimmed fallback (analysis wasn't ready); a better one may still arrive.
    var trimIsFallback = false
    /// Frames dropped from the head of the incoming baked audio when started late (voice timeline = output time - this).
    var startSkip: Int64 = 0
    var started = false
    var alive = true
    var bake: BakeJob?
    var ready: [ReadyChunk] = []
    /// Body audio decoded in memory, contiguous from `bodyNext`. The node never reads the disk itself: slow
    /// volumes (USB/exFAT) stall lazily read `scheduleSegment`s and the node plays silence.
    var bodyReady: [BodyChunk] = []
    var bodyReadInFlight = false
    let bodyReader: BodyReader
    var attached = false
    var refreshingBeats = false

    init(track: Track, analysis: TrackAnalysis?) throws {
        id = Self.counter.withLock { $0 += 1; return $0 }
        self.track = track
        file = try AVAudioFile(forReading: track.url)
        bodyReader = BodyReader(url: track.url)
        format = file.processingFormat
        sampleRate = format.sampleRate
        trimIsFallback = analysis?.trim == nil
        let t = analysis?.trim ?? TrimInfo.untrimmed(totalFrames: file.length, sampleRate: format.sampleRate)
        trim = t
        beats = analysis?.beats
        bodyNext = t.startFrame
        bodyLimit = t.endFrame
    }

    // MARK: Position

    /// Frames the node has rendered since `play` (nil before it renders).
    func playedSamples() -> Int64? {
        guard started, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return nil }
        return max(0, pt.sampleTime)
    }

    /// Source frame (fractional) corresponding to voice sample `s`.
    func sourceFrame(atSample s: Int64) -> Double? {
        guard let item = items.last(where: { $0.start <= s }) ?? items.first else { return nil }
        let off = min(max(s - item.start, 0), item.length)
        switch item.kind {
        case .body(let src): return Double(src + off)
        case .baked(let side, let plan, let firstOut): return plan.sourcePosition(side, atFrame: firstOut + off)
        }
    }

    func pruneItems(before sample: Int64) {
        while items.count > 2, items[0].end < sample - Int64(2 * sampleRate) { items.removeFirst() }
    }

    // MARK: Scheduling

    /// Frames scheduled beyond `played`.
    func ahead(of played: Int64) -> Int64 { scheduledEnd - played }

    /// Schedules a raw (already processed) buffer that mirrors the source from `src` (fades).
    func scheduleRaw(_ buffer: AVAudioPCMBuffer, src: Int64) {
        let n = Int64(buffer.frameLength)
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        items.append(Item(start: scheduledEnd, length: n, kind: .body(src: src)))
        scheduledEnd += n
        bodyNext = src + n
    }

    func scheduleBaked(_ buffer: AVAudioPCMBuffer, side: TransitionSide, plan: TransitionPlan, firstOut: Int64) {
        let n = Int64(buffer.frameLength)
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        items.append(Item(start: scheduledEnd, length: n, kind: .baked(side: side, plan: plan, firstOut: firstOut)))
        scheduledEnd += n
    }

    /// Synchronous raw read on the engine queue (ramped).
    func readRamp(start: Int64, count: Int, gain: (Double) -> Float) -> AVAudioPCMBuffer? {
        let ch = TransitionBaker.rawRamp(file: file, start: start, count: count, gain: gain)
        return TransitionBaker.makeBuffer(ch, format: format)
    }

    func teardown() {
        alive = false
        ready.removeAll()
        bodyReady.removeAll()
        node.stop()
    }
}
