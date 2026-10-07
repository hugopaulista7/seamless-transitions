import Foundation

/// Runs silence + beat analysis with caching, in-flight dedup and a prioritised work queue.
///
/// Background (low priority) work sits in a plain pending list (not suspended tasks) and is pumped with at most
/// `maxBackground` concurrent computes. A high priority request for a key that hasn't started computing pulls it out
/// of the queue and computes it immediately, unthrottled, so it never waits behind the library crawl.
actor TrackAnalyzer {
    typealias Summary = AnalysisCache.Summary

    /// Emits (track id, result) whenever an analysis finishes (not for cache hits or transient failures).
    nonisolated let updates: AsyncStream<(String, TrackAnalysis)>
    private let continuation: AsyncStream<(String, TrackAnalysis)>.Continuation

    private struct Job {
        let track: Track
        let key: String
        /// QoS of the compute. `.background` also throttles its disk reads behind playback's.
        var priority: TaskPriority = .utility
    }

    private let cache: AnalysisCache
    /// Queued background jobs by key, with their queue order and the callers awaiting each.
    private var pending: [String: Job] = [:]
    private var pendingOrder: [String] = []
    /// Keys currently being computed.
    private var computing: Set<String> = []
    private var waiters: [String: [CheckedContinuation<TrackAnalysis, Never>]] = [:]
    private var running = 0
    private static let maxBackground = 2

    init(cache: AnalysisCache = AnalysisCache()) {
        self.cache = cache
        (updates, continuation) = AsyncStream.makeStream(of: (String, TrackAnalysis).self, bufferingPolicy: .unbounded)
    }

    deinit { continuation.finish() }

    /// Cache lookup only; never does work.
    func cached(_ track: Track) async -> TrackAnalysis? {
        await cache.get(AnalysisCache.key(for: track))
    }

    /// Index-only cache lookup for many tracks (track id -> summary), without reading beat grids.
    func cachedSummaries(_ tracks: [Track]) async -> [String: Summary] {
        let keys = await Task.detached(priority: .utility) { tracks.map { AnalysisCache.key(for: $0) } }.value
        let sums = await cache.summaries(for: keys)
        var out: [String: Summary] = [:]
        for (t, s) in zip(tracks, sums) { if let s { out[t.id] = s } }
        return out
    }

    func flush() async { await cache.flush() }

    /// Returns analysis, computing if needed. Low priority work is queued and throttled; higher priority starts
    /// right away (taking the job over from the queue if it was waiting there).
    func analysis(for track: Track, priority: TaskPriority = .userInitiated) async -> TrackAnalysis {
        let key = AnalysisCache.key(for: track)
        if let hit = await cache.get(key) { return hit }
        // Re-check after the suspension above: another caller may have started this key meanwhile.
        let high = priority > .utility
        return await withCheckedContinuation { (c: CheckedContinuation<TrackAnalysis, Never>) in
            waiters[key, default: []].append(c)
            if computing.contains(key) { return }
            if high {
                let job = pending.removeValue(forKey: key) ?? Job(track: track, key: key)
                pendingOrder.removeAll { $0 == key }
                start(job, background: false, priority: priority)
            } else if pending[key] == nil {
                pending[key] = Job(track: track, key: key, priority: priority)
                pendingOrder.append(key)
                pump()
            }
        }
    }

    /// Fire-and-forget analysis of many tracks, in the given order (closest-to-play-position first).
    func prefetch(_ tracks: [Track], priority: TaskPriority) async {
        if priority > .utility {
            for track in tracks { Task(priority: priority) { _ = await self.analysis(for: track, priority: priority) } }
            return
        }
        let keys = await Task.detached(priority: .utility) { tracks.map { AnalysisCache.key(for: $0) } }.value
        let sums = await cache.summaries(for: keys)
        var fresh: [String] = []
        for (i, track) in tracks.enumerated() where sums[i] == nil {
            let key = keys[i]
            if computing.contains(key) { continue }
            if pending[key] == nil { pending[key] = Job(track: track, key: key, priority: priority) } else { pending[key]?.priority = priority }
            fresh.append(key)
        }
        // Prefetch order wins over earlier queue order for the keys it names.
        let named = Set(fresh)
        pendingOrder = fresh + pendingOrder.filter { !named.contains($0) }
        pump()
    }

    /// Moves queued background jobs for the given track ids to the front, in that order.
    func prioritize(ids: [String]) {
        guard !pendingOrder.isEmpty else { return }
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var front: [(Int, String)] = []
        var rest: [String] = []
        for key in pendingOrder {
            if let r = pending[key].flatMap({ rank[$0.track.id] }) { front.append((r, key)) } else { rest.append(key) }
        }
        pendingOrder = front.sorted { $0.0 < $1.0 }.map(\.1) + rest
    }

    /// Drops queued background work nobody is waiting on (running computes can't be interrupted and finish normally).
    func cancelBackground() {
        pendingOrder.removeAll { key in
            if waiters[key]?.isEmpty ?? true { pending[key] = nil; return true }
            return false
        }
    }

    // MARK: Work

    private func pump() {
        while running < Self.maxBackground, !pendingOrder.isEmpty {
            let key = pendingOrder.removeFirst()
            guard let job = pending.removeValue(forKey: key) else { continue }
            running += 1
            start(job, background: true, priority: job.priority)
        }
    }

    private func start(_ job: Job, background: Bool, priority: TaskPriority) {
        computing.insert(job.key)
        let url = job.track.url, id = job.track.id, key = job.key
        Task {
            let outcome = await Task.detached(priority: priority) { Self.compute(url: url) }.value
            await finish(key: key, id: id, outcome, background: background)
        }
    }

    private func finish(key: String, id: String, _ outcome: Outcome, background: Bool) async {
        // Keep `computing` set across the cache write so concurrent callers join instead of recomputing.
        if outcome.persist {
            await cache.set(key, outcome.analysis)
            continuation.yield((id, outcome.analysis))
        }
        computing.remove(key)
        for w in waiters.removeValue(forKey: key) ?? [] { w.resume(returning: outcome.analysis) }
        if background { running -= 1; pump() }
    }

    struct Outcome: Sendable {
        var analysis: TrackAnalysis
        /// False for transient failures (unreadable file etc.), which must not be cached as "unplayable".
        var persist: Bool
    }

    nonisolated static func compute(url: URL) -> Outcome {
        let trim: TrimInfo?
        do { trim = try SilenceDetector.detect(url: url) } catch {
            return Outcome(analysis: TrackAnalysis(trim: nil, beats: nil), persist: false)
        }
        guard let trim else { return Outcome(analysis: TrackAnalysis(trim: nil, beats: nil), persist: true) } // truly silent
        do {
            let beats = try BeatAnalyzer.analyze(url: url, trim: trim)
            return Outcome(analysis: TrackAnalysis(trim: trim, beats: beats), persist: true)
        } catch {
            return Outcome(analysis: TrackAnalysis(trim: trim, beats: nil), persist: false)
        }
    }
}
