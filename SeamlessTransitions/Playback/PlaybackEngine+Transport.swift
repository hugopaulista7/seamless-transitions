@preconcurrency import AVFoundation
import Foundation

/// Starting, seeking, skipping, pausing and tearing down playback.
extension PlaybackEngine {
    // MARK: Control context

    /// Track the user is "on" (dominant), with its analysis and file position; works live and paused.
    func controlContext() -> (track: Track, analysis: TrackAnalysis, position: Double)? {
        if state == .paused, primary == nil || pausedAnchor != nil {
            guard let held = heldTelemetry, let anchor = pausedAnchor ?? rebuilding?.anchor else { return nil }
            switch anchor {
            case .body(let t, let an, _): return (t, an, held.position)
            case .transition(_, let a, let aAn, let b, let bAn, _):
                return held.trackID == b.id ? (b, bAn, held.position) : (a, aAn, held.position)
            }
        }
        guard let v = dominantVoice(), let t = currentTelemetry() else { return nil }
        return (v.track, TrackAnalysis(trim: v.trim, beats: v.beats), t.position)
    }

    // MARK: Engine plumbing

    func ensureEngineRunning() throws {
        if !graphReady {
            _ = avEngine.mainMixerNode
            graphReady = true
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: avEngine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.assumeIsolated { $0.handleConfigChange() } }
            }
        }
        if !avEngine.isRunning {
            log.notice("starting audio engine (output \(Self.describe(self.avEngine.outputNode.outputFormat(forBus: 0)), privacy: .public))")
            do {
                avEngine.prepare()
                try avEngine.start()
            } catch {
                throw PlaybackError.engineStart(error)
            }
        }
        #if DEBUG
        GapMonitor.shared.install(on: avEngine.mainMixerNode)
        #endif
    }

    func attach(_ v: Voice) {
        avEngine.attach(v.node)
        avEngine.connect(v.node, to: avEngine.mainMixerNode, format: v.format)
        v.attached = true
    }

    func detach(_ v: Voice) {
        v.teardown()
        if v.attached {
            avEngine.detach(v.node)
            v.attached = false
        }
    }

    func startTick() {
        guard tickTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.assumeIsolated { $0.tick() }
        }
        t.schedule(deadline: .now() + Tuning.tickInterval, repeating: Tuning.tickInterval, leeway: .milliseconds(5))
        t.resume()
        tickTimer = t
        #if DEBUG
        GapMonitor.shared.setPlaying(true)
        #endif
    }

    func stopTick() {
        tickTimer?.cancel()
        tickTimer = nil
        lastTickUptime = nil
        #if DEBUG
        GapMonitor.shared.setPlaying(false)
        #endif
    }

    // MARK: Loading a track

    /// Starts (async) playback of `order[p]`, skipping unplayable tracks in direction `step`.
    func beginLoading(position p: Int, step: Int) {
        epoch += 1
        let e = epoch
        cancelCommit()
        loadingTarget = p
        if state == .paused { suspendNow() }
        pausedAnchor = nil
        lastAnchor = nil
        state = .playing
        Task { await self.startAt(position: p, step: step, epoch: e) }
    }

    private func startAt(position p: Int, step: Int, epoch e: Int) async {
        var pos = p
        while order.indices.contains(pos), e == epoch {
            let ti = order[pos]
            guard tracks.indices.contains(ti) else { break }
            let track = tracks[ti]
            if unplayableIDs.contains(track.id) { pos += step; continue }
            let analysis = await resolveAnalysis(track)
            guard e == epoch else { return }
            guard let analysis, let trim = analysis.trim else {
                unplayableIDs.insert(track.id)
                pos += step
                continue
            }
            loadingTarget = pos
            kickPrefetch(from: pos)
            let had = primary != nil
            do {
                try beginBody(track: track, analysis: analysis, frame: trim.startFrame,
                              fadeIn: had ? Tuning.quickFade : Tuning.firstFade, fadeOutOld: Tuning.quickFade)
                return
            } catch PlaybackError.engineStart(let underlying) {
                // The audio engine failed, not the track: don't grey out the queue.
                log.error("audio engine failed to start: \(underlying.localizedDescription, privacy: .public)")
                stop()
                return
            } catch {
                log.error("cannot start \(track.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                unplayableIDs.insert(track.id)
                pos += step
            }
        }
        if e == epoch { stop() }
    }

    /// Cached analysis, else a quick trim-only scan (beats arrive later through the analyzer). nil = unplayable.
    func resolveAnalysis(_ track: Track) async -> TrackAnalysis? {
        if let c = await analyzer.cached(track) { return c.trim == nil ? nil : c }
        let url = track.url
        let trim = await Task.detached(priority: .userInitiated) { try? SilenceDetector.detect(url: url) }.value
        guard let trim else { return nil }
        return TrackAnalysis(trim: trim, beats: nil)
    }

    func kickPrefetch(from position: Int) {
        let upcoming = (position...(position + 2)).compactMap { p in order.indices.contains(p) ? tracks[order[p]] : nil }
        let analyzer = self.analyzer
        // Queued (max 2 at once) ahead of the library crawl; not userInitiated, which would compete with playback reads.
        Task { await analyzer.prefetch(upcoming, priority: .utility) }
    }

    // MARK: Starting a voice

    static func fadeCurve(seconds: Double) -> (Double) -> Float {
        seconds < 0.1 ? { Float($0) } : { Float(sin(Double.pi / 2 * $0)) }
    }

    /// Replaces whatever is playing with `track` from `frame`, fading the old voices out and the new one in.
    func beginBody(track: Track, analysis: TrackAnalysis, frame: Int64, fadeIn: Double, fadeOutOld: Double) throws {
        let v = try Voice(track: track, analysis: analysis)
        log.debug("beginBody \(track.fileName, privacy: .public) frame=\(frame) fadeIn=\(fadeIn) fadeOutOld=\(fadeOutOld)")
        if state == .paused {
            // User paused while loading: remember where to start on resume.
            pausedAnchor = .body(track: track, analysis: TrackAnalysis(trim: v.trim, beats: v.beats), frame: frame)
            heldTelemetry = Telemetry(trackID: track.id, position: Double(frame) / v.sampleRate,
                                      duration: Double(v.file.length) / v.sampleRate, inTransition: false, progress: 0,
                                      bpm: v.beats?.isReliable == true ? v.beats?.bpm : nil)
            loadingTarget = nil
            return
        }
        try ensureEngineRunning()
        avEngine.mainMixerNode.outputVolume = 1
        attach(v)
        let start = min(max(frame, v.trim.startFrame), max(v.trim.endFrame - 1, v.trim.startFrame))
        v.bodyNext = start
        let hadAudio = primary != nil
        let fadeSeconds = hadAudio ? fadeIn : min(fadeIn, 0.03)
        let fadeFrames = min(Int(fadeSeconds * v.sampleRate), Int(max(v.trim.endFrame - start, 0)))
        if fadeFrames > 0, let buf = v.readRamp(start: start, count: fadeFrames, gain: Self.fadeCurve(seconds: fadeSeconds)) {
            v.scheduleRaw(buf, src: start)
        }
        // First stretch of body read here so the node has audio before the background reader delivers.
        let finalLimit = v.trim.endFrame - Int64(Tuning.endFade * v.sampleRate)
        let first = min(Int64(Tuning.bodyStartSeconds * v.sampleRate), max(finalLimit - v.bodyNext, 0))
        if first > 0, let buf = v.readRamp(start: v.bodyNext, count: Int(first), gain: { _ in 1 }) {
            v.scheduleRaw(buf, src: v.bodyNext)
        }
        retireCurrent(fade: hadAudio ? fadeOutOld : 0)
        primary = v
        transition = nil
        loadingTarget = nil
        heldTelemetry = nil
        state = .playing
        topUpBody(v, played: 0)
        v.started = true
        v.node.play()
        startTick()
    }

    // MARK: Retiring voices

    /// Moves the current voices out (fading them over `fade` seconds, or dropping immediately).
    func retireCurrent(fade: Double) {
        cancelCommit()
        let old = [primary, transition?.b].compactMap { $0 }
        primary = nil
        transition = nil
        for v in old { fadeOut(v, seconds: fade) }
    }

    func fadeOut(_ v: Voice, seconds: Double) {
        v.bodyEnabled = false
        v.bake = nil
        v.ready.removeAll()
        v.finished = true
        guard seconds > 0.002, v.started else {
            detach(v)
            return
        }
        fading.append(v)
        let node = v.node, id = v.id
        startRamp(duration: seconds, apply: { u in node.volume = Float(cos(Double.pi / 2 * u)) }, completion: { engine in
            if let v = engine.voice(withID: id) { engine.detach(v) }
            engine.fading.removeAll { $0.id == id }
        })
    }

    /// Immediately removes every voice (no fade). Engine keeps running.
    func dropAllVoices() {
        cancelCommit()
        cancelAllRamps()
        for v in [primary, transition?.b].compactMap({ $0 }) + fading { detach(v) }
        primary = nil
        transition = nil
        fading.removeAll()
        pauseRampID = nil
        avEngine.mainMixerNode.outputVolume = 1
    }

    // MARK: Pause / resume

    func pause() {
        guard state == .playing else { return }
        if primary != nil {
            pausedAnchor = makeAnchor()
            heldTelemetry = liveTelemetry()
        }
        state = .paused
        cancelCommit()
        stopTick()
        guard primary != nil else { return }
        let mixer = avEngine.mainMixerNode
        pauseRampID = startRamp(duration: Tuning.pauseFade, apply: { u in mixer.outputVolume = Float(1 - u) },
                                completion: { engine in engine.suspendNow() })
    }

    /// Tears the voices down and pauses the engine (state must already be `.paused`).
    func suspendNow() {
        cancelRamp(pauseRampID)
        if primary != nil || !fading.isEmpty { dropAllVoices() }
        pauseRampID = nil
        if avEngine.isRunning { avEngine.pause() }
        avEngine.mainMixerNode.outputVolume = 1
    }

    func resume() {
        guard state == .paused else { return }
        if let id = pauseRampID, primary != nil {
            // Pause ramp still running: voices are alive, just fade back up.
            cancelRamp(id)
            pauseRampID = nil
            state = .playing
            pausedAnchor = nil
            heldTelemetry = nil
            let mixer = avEngine.mainMixerNode
            let from = mixer.outputVolume
            startRamp(duration: Tuning.pauseFade, apply: { u in mixer.outputVolume = Float(Double(from) + (1 - Double(from)) * u) })
            startTick()
            return
        }
        guard let anchor = pausedAnchor ?? rebuilding?.anchor else {
            if let t = loadingTarget { beginLoading(position: t, step: 1) }
            return
        }
        epoch += 1
        let e = epoch
        state = .playing
        pausedAnchor = nil
        rebuilding = (anchor, e)
        Task { await self.rebuild(anchor, epoch: e) }
    }

    func rebuild(_ anchor: Anchor, epoch e: Int) async {
        defer { if rebuilding?.epoch == e { rebuilding = nil } }
        guard e == epoch else { return }
        switch anchor {
        case .body(let track, let analysis, let frame):
            do {
                try beginBody(track: track, analysis: analysis, frame: frame, fadeIn: Tuning.pauseFade, fadeOutOld: 0)
            } catch {
                log.error("resume failed: \(error.localizedDescription, privacy: .public)")
                stop()
            }
        case .transition(let plan, let a, let aAn, let b, let bAn, let tau):
            await rebuildTransition(plan: plan, a: a, aAnalysis: aAn, b: b, bAnalysis: bAn, tau: tau, epoch: e)
        }
    }

    // MARK: Seek

    func seek(to seconds: Double) {
        guard let ctx = controlContext(), let trim = ctx.analysis.trim else { return }
        let sr = trim.sampleRate
        let hi = max(trim.startFrame, trim.endFrame - Int64(0.5 * sr))
        let frame = min(max(Int64((seconds * sr).rounded()), trim.startFrame), hi)
        epoch += 1
        if state == .paused {
            pausedAnchor = .body(track: ctx.track, analysis: ctx.analysis, frame: frame)
            heldTelemetry = Telemetry(trackID: ctx.track.id, position: Double(frame) / sr, duration: Double(trim.totalFrames) / sr,
                                      inTransition: false, progress: 0,
                                      bpm: ctx.analysis.beats?.isReliable == true ? ctx.analysis.beats?.bpm : nil)
            return
        }
        do {
            try beginBody(track: ctx.track, analysis: ctx.analysis, frame: frame, fadeIn: Tuning.seekFade, fadeOutOld: Tuning.seekFade)
        } catch {
            log.error("seek failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Stop

    func stop() {
        epoch += 1
        let wasPlaying = state == .playing
        if state == .paused { suspendNow() }
        retireCurrent(fade: wasPlaying ? 0.02 : 0)
        loadingTarget = nil
        pausedAnchor = nil
        heldTelemetry = nil
        lastAnchor = nil
        state = .idle
        stopTick()
    }

    // MARK: Anchors

    func makeAnchor() -> Anchor? {
        guard let a = primary else { return nil }
        let played = a.playedSamples() ?? 0
        let an = TrackAnalysis(trim: a.trim, beats: a.beats)
        if let t = transition, t.b.started, let tau = tau(of: t), tau < t.plan.duration {
            return .transition(plan: t.plan, a: a.track, aAnalysis: an, b: t.b.track,
                               bAnalysis: TrackAnalysis(trim: t.b.trim, beats: t.b.beats), tau: tau)
        }
        let src = Int64((a.sourceFrame(atSample: played) ?? Double(a.bodyNext)).rounded())
        return .body(track: a.track, analysis: an, frame: min(max(src, a.trim.startFrame), a.trim.endFrame - 1))
    }

    // MARK: Device change

    static func describe(_ f: AVAudioFormat) -> String { "\(f.sampleRate) Hz \(f.channelCount) ch" }

    func handleConfigChange() {
        log.notice("config change: state=\(String(describing: self.state), privacy: .public) running=\(self.avEngine.isRunning) output=\(Self.describe(self.avEngine.outputNode.outputFormat(forBus: 0)), privacy: .public)")
        guard state != .idle else { return }
        let anchor = state == .paused ? (pausedAnchor ?? rebuilding?.anchor)
            : (primary == nil ? rebuilding?.anchor : nil) ?? lastAnchor ?? makeAnchor()
        if state == .playing, let t = currentTelemetry() { heldTelemetry = t }
        stopTick()
        dropAllVoices()
        avEngine.stop()
        avEngine.connect(avEngine.mainMixerNode, to: avEngine.outputNode, format: nil)
        guard state == .playing else { return }
        if let t = loadingTarget { // a load was pending: restart it rather than rebuilding the old track
            beginLoading(position: t, step: 1)
            return
        }
        guard let anchor else { return }
        epoch += 1
        let e = epoch
        rebuilding = (anchor, e)
        Task { await self.rebuild(anchor, epoch: e) }
    }
}
