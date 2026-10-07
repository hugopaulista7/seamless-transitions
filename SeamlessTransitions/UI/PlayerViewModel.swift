import AppKit
import Observation

@MainActor @Observable
final class PlayerViewModel {
    // Library
    private(set) var tracks: [Track] = []
    private(set) var order = PlayOrder(count: 0, shuffled: false)
    private(set) var infos: [String: MetadataLoader.Info] = [:]
    private(set) var bpm: [String: Double] = [:]
    /// Track ids that cannot be played.
    private(set) var unplayable: Set<String> = []
    private(set) var folderName: String?
    private(set) var isScanning = false

    // Playback
    private(set) var snapshot = EngineSnapshot.idle
    /// Separate from `snapshot` (replaced ~15x/s) so the track list doesn't re-evaluate on every position update.
    private(set) var isPlaying = false
    private(set) var transitionSeconds: Double
    var shuffle: Bool { didSet { UserDefaults.standard.set(shuffle, forKey: "shuffle") } }

    @ObservationIgnored let analyzer = TrackAnalyzer()
    @ObservationIgnored let engine: PlaybackEngine
    @ObservationIgnored let metadata = MetadataLoader()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var pendingInfos: [String: MetadataLoader.Info] = [:]
    @ObservationIgnored private var pendingBPM: [String: Double] = [:]
    @ObservationIgnored private var pendingUnplayable: Set<String> = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastPosition: Int?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init() {
        engine = PlaybackEngine(analyzer: analyzer)
        let d = UserDefaults.standard
        let saved = d.object(forKey: "transitionSeconds") as? Double ?? 60
        transitionSeconds = min(max(saved, TransitionSettings.range.lowerBound), TransitionSettings.range.upperBound)
        shuffle = d.bool(forKey: "shuffle")
    }

    // MARK: Derived

    var currentTrackIndex: Int? { order.currentTrackIndex.flatMap { tracks.indices.contains($0) ? $0 : nil } }
    var currentTrack: Track? { currentTrackIndex.map { tracks[$0] } }
    var snapshotTrack: Track? { snapshot.currentTrackIndex.flatMap { tracks.indices.contains($0) ? tracks[$0] : nil } }
    var hasTracks: Bool { !tracks.isEmpty }

    func title(for track: Track) -> String { infos[track.id]?.title ?? track.fileName }
    func artist(for track: Track) -> String? { infos[track.id]?.artist }

    // MARK: Lifecycle

    /// Idempotent. Call once from the root view's `.task`.
    func start() async {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [analyzer] _ in
            // Persist the analysis index before quitting (bounded wait).
            let done = DispatchSemaphore(value: 0)
            Task.detached { await analyzer.flush(); done.signal() }
            _ = done.wait(timeout: .now() + 2)
        }
        Task { [analyzer] in
            for await (id, analysis) in analyzer.updates { self.enqueue(id, analysis) }
        }
        Task { await pollLoop() }
        await restoreLastFolder()
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let s = await engine.snapshot()
            if s != snapshot { snapshot = s }
            if s.isPlaying != isPlaying { isPlaying = s.isPlaying }
            if let p = s.currentOrderPosition, p != order.position, order.order.indices.contains(p) { order.position = p }
            if s.currentOrderPosition != lastPosition { lastPosition = s.currentOrderPosition; reprioritize() }
            let ids = Set(s.unplayable.compactMap { tracks.indices.contains($0) ? tracks[$0].id : nil })
            if !ids.isSubset(of: unplayable) { unplayable.formUnion(ids) }
            try? await Task.sleep(for: .milliseconds(66))
        }
    }

    /// Buffers per-track results and publishes them in one batch (every list row observes these dictionaries).
    private func enqueue(_ id: String, _ analysis: TrackAnalysis) {
        if let b = analysis.beats, b.isReliable { pendingBPM[id] = b.bpm }
        if analysis.trim == nil { pendingUnplayable.insert(id) }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            flushPending()
        }
    }

    private func flushPending() {
        flushTask = nil
        if !pendingBPM.isEmpty { bpm.merge(pendingBPM) { _, new in new }; pendingBPM = [:] }
        if !pendingUnplayable.isEmpty { unplayable.formUnion(pendingUnplayable); pendingUnplayable = [] }
        if !pendingInfos.isEmpty { infos.merge(pendingInfos) { _, new in new }; pendingInfos = [:] }
    }

    /// Queued background analysis follows the play position: tracks after the current one first.
    private func reprioritize() {
        guard !order.order.isEmpty else { return }
        let start = order.position
        let ids = (0..<min(order.order.count, 300)).compactMap { k -> String? in
            let i = order.order[(start + k) % order.order.count]
            return tracks.indices.contains(i) ? tracks[i].id : nil
        }
        Task { [analyzer] in await analyzer.prioritize(ids: ids) }
    }

    // MARK: Folder

    @ObservationIgnored private let access = FolderAccess()

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder with music"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? access.choose(url)
        Task { await load(folder: url) }
    }

    func restoreLastFolder() async {
        guard let url = access.restore() else { return }
        await load(folder: url)
    }

    func load(folder: URL) async {
        loadGeneration += 1
        let gen = loadGeneration
        await engine.stop()
        folderName = folder.lastPathComponent
        isScanning = true
        tracks = []; order = PlayOrder(count: 0, shuffled: false)
        await analyzer.cancelBackground()
        flushTask?.cancel(); flushTask = nil
        pendingInfos = [:]; pendingBPM = [:]; pendingUnplayable = []
        infos = [:]; bpm = [:]; unplayable = []
        snapshot = .idle; isPlaying = false

        let found = await Task.detached(priority: .userInitiated) { (try? FolderScanner.scan(folder)) ?? [] }.value
        guard gen == loadGeneration else { return }
        tracks = found
        order = PlayOrder(count: found.count, shuffled: shuffle)
        isScanning = false
        await pushQueue()
        await engine.setSettings(TransitionSettings(seconds: transitionSeconds))
        let sums = await analyzer.cachedSummaries(found)
        guard gen == loadGeneration else { return }
        for (id, s) in sums {
            if let b = s.reliableBPM { pendingBPM[id] = b }
            if !s.playable { pendingUnplayable.insert(id) }
        }
        flushPending()
        // Uncached tracks, nearest the play position first.
        let ordered = order.order.map { found[$0] }.filter { sums[$0.id] == nil }
        await analyzer.prefetch(ordered, priority: .background)
    }

    private func pushQueue() async {
        await engine.setQueue(QueueSnapshot(tracks: tracks, order: order.order, position: order.position))
    }

    // MARK: Metadata

    /// Called from a per-row `.task`, so SwiftUI cancels it when the row scrolls away.
    func loadInfo(for track: Track) async {
        guard infos[track.id] == nil, pendingInfos[track.id] == nil else { return }
        let info = await metadata.info(for: track)
        guard !Task.isCancelled else { return }
        pendingInfos[track.id] = info
        scheduleFlush()
    }

    // MARK: Transport

    func playTrack(index: Int) {
        guard tracks.indices.contains(index) else { return }
        order.moveTo(trackIndex: index)
        let p = order.position
        Task { await engine.play(orderPosition: p) }
    }

    func togglePlayPause() {
        guard hasTracks else { return }
        if snapshot.currentOrderPosition == nil {
            let p = order.position
            Task { await engine.play(orderPosition: p) }
        } else {
            Task { await engine.togglePlayPause() }
        }
    }

    func next() { guard hasTracks else { return }; Task { await engine.next() } }
    func previous() { guard hasTracks else { return }; Task { await engine.previous() } }

    func seek(fraction: Double) {
        let d = snapshot.duration
        guard d > 0 else { return }
        let s = min(max(fraction, 0), 1) * d
        Task { await engine.seek(to: s) }
    }

    func setShuffle(_ on: Bool) {
        shuffle = on
        guard hasTracks else { return }
        order.setShuffle(on)
        Task { await pushQueue() }
        reprioritize()
    }

    func setTransitionSeconds(_ v: Double) {
        transitionSeconds = min(max(v, TransitionSettings.range.lowerBound), TransitionSettings.range.upperBound)
        UserDefaults.standard.set(transitionSeconds, forKey: "transitionSeconds")
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await engine.setSettings(TransitionSettings(seconds: transitionSeconds))
        }
    }
}
