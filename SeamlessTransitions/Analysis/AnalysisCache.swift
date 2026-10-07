import CryptoKit
import Foundation

/// Persistent cache of per-track analysis, keyed by path+size+mtime+algorithm version.
///
/// Layout: a small JSON index (trim, tempo, downbeat indices; ~150 B/track) is loaded off the critical path, and
/// each track's beat grid (~1000 times) lives in its own binary sidecar next to the index, loaded lazily on `get`.
/// Index saves are throttled (not debounce-restarted) so a long library crawl still persists; `flush()` forces one.
actor AnalysisCache {
    static let algorithmVersion = 2

    /// Index-only view of a cached entry (no sidecar read).
    struct Summary: Sendable, Equatable {
        /// False when the file is silent (nothing to play).
        var playable: Bool
        /// Tempo when the beat grid is reliable enough to beatmatch.
        var reliableBPM: Double?
    }

    private struct BeatMeta: Codable {
        var bpm: Double
        var confidence: Double
        var headDownbeatIndex: Int
        var tailDownbeatIndex: Int
        var headCount: Int
        var tailCount: Int

        var reliable: Bool { confidence >= BeatInfo.minConfidence && bpm > 0 && headCount >= 8 && tailCount >= 8 }
    }

    private struct Entry: Codable {
        var trim: TrimInfo?
        var beats: BeatMeta?
    }

    private static let minSaveInterval = 30.0
    private static let firstSaveDelay = 2.0

    private let fileURL: URL
    private let sidecarDir: URL
    private let indexLoad: Task<[String: Entry], Never>
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var lastSave: Date?

    init(fileURL: URL? = nil) {
        let dir = URL.applicationSupportDirectory.appending(path: "SeamlessTransitions", directoryHint: .isDirectory)
        let file = fileURL ?? dir.appending(path: "analysis-index.json")
        self.fileURL = file
        sidecarDir = file.deletingLastPathComponent().appending(path: "beats", directoryHint: .isDirectory)
        let removeLegacy = fileURL == nil ? dir.appending(path: "analysis.json") : nil
        indexLoad = Task.detached(priority: .utility) {
            if let removeLegacy { try? FileManager.default.removeItem(at: removeLegacy) }
            guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
            return decoded
        }
    }

    func get(_ key: String) async -> TrackAnalysis? {
        await ensureLoaded()
        guard let e = entries[key] else { return nil }
        guard let meta = e.beats else { return TrackAnalysis(trim: e.trim, beats: nil) }
        // Sidecar missing/corrupt: treat the whole entry as a miss so it is recomputed.
        guard let beats = Self.readSidecar(sidecarURL(key), meta: meta) else { return nil }
        return TrackAnalysis(trim: e.trim, beats: beats)
    }

    func set(_ key: String, _ value: TrackAnalysis) async {
        await ensureLoaded()
        var entry = Entry(trim: value.trim, beats: nil)
        if let b = value.beats {
            entry.beats = BeatMeta(bpm: b.bpm, confidence: b.confidence, headDownbeatIndex: b.headDownbeatIndex,
                                   tailDownbeatIndex: b.tailDownbeatIndex, headCount: b.headBeats.count, tailCount: b.tailBeats.count)
            do {
                try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
                try Self.encodeSidecar(b).write(to: sidecarURL(key), options: .atomic)
            } catch {
                NSLog("AnalysisCache sidecar write failed: \(error)")
                return
            }
        }
        entries[key] = entry
        dirty = true
        scheduleSave()
    }

    /// Index-only lookup for many keys at once (nil = not cached).
    func summaries(for keys: [String]) async -> [Summary?] {
        await ensureLoaded()
        return keys.map { k in
            entries[k].map { Summary(playable: $0.trim != nil, reliableBPM: $0.beats.flatMap { $0.reliable ? $0.bpm : nil }) }
        }
    }

    /// Writes the index now if anything changed since the last save.
    func flush() async {
        await ensureLoaded()
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Cache key for a track's current file state.
    static func key(for track: Track) -> String {
        // A fresh URL: `Track.url` caches resource values after the first lookup, which would go stale.
        let values = try? URL(fileURLWithPath: track.url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(track.id)|\(size)|\(mtime)|v\(algorithmVersion)"
    }

    // MARK: Index

    private func ensureLoaded() async {
        if loaded { return }
        let disk = await indexLoad.value
        if loaded { return }
        loaded = true
        entries = disk.merging(entries) { _, mem in mem }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let delay = lastSave.map { max(Self.firstSaveDelay, Self.minSaveInterval - Date().timeIntervalSince($0)) } ?? Self.firstSaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.timerFired()
        }
    }

    private func timerFired() {
        saveTask = nil
        save()
    }

    private func save() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
            dirty = false
            lastSave = Date()
        } catch {
            NSLog("AnalysisCache save failed: \(error)")
        }
    }

    // MARK: Sidecars

    private func sidecarURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return sidecarDir.appending(path: digest + ".beats")
    }

    /// Binary: u32 headCount, u32 tailCount, f64 headBase, f64 tailBase, then f32 offsets from each base
    /// (offsets stay < 5 min, so f32 resolution is ~30 us).
    private static func encodeSidecar(_ b: BeatInfo) -> Data {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(UInt32(b.headBeats.count)); put(UInt32(b.tailBeats.count))
        let hb = b.headBeats.first ?? 0, tb = b.tailBeats.first ?? 0
        put(hb); put(tb)
        for t in b.headBeats { put(Float32(t - hb)) }
        for t in b.tailBeats { put(Float32(t - tb)) }
        return d
    }

    private static func readSidecar(_ url: URL, meta: BeatMeta) -> BeatInfo? {
        guard let d = try? Data(contentsOf: url), d.count >= 24 else { return nil }
        let hc = Int(d.loadLE(UInt32.self, at: 0)), tc = Int(d.loadLE(UInt32.self, at: 4))
        guard hc == meta.headCount, tc == meta.tailCount, d.count == 24 + 4 * (hc + tc) else { return nil }
        let hb = d.loadLE(Double.self, at: 8), tb = d.loadLE(Double.self, at: 16)
        let head = (0..<hc).map { hb + Double(d.loadLE(Float32.self, at: 24 + 4 * $0)) }
        let tail = (0..<tc).map { tb + Double(d.loadLE(Float32.self, at: 24 + 4 * (hc + $0))) }
        return BeatInfo(bpm: meta.bpm, confidence: meta.confidence, headBeats: head, tailBeats: tail,
                        headDownbeatIndex: meta.headDownbeatIndex, tailDownbeatIndex: meta.tailDownbeatIndex)
    }
}

private extension Data {
    func loadLE<T>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
