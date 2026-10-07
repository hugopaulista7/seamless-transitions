@preconcurrency import AVFoundation
import Foundation

/// Rolling scheduler (`tick`), transition commit and the bake pump.
extension PlaybackEngine {
    // MARK: Tick

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastTickUptime, now - last > 0.25 { log.notice("tick stall \(now - last, format: .fixed(precision: 3)) s") }
        lastTickUptime = now
        guard state == .playing, let a = primary else { return }
        let played = a.playedSamples() ?? 0
        a.pruneItems(before: played)
        topUpBody(a, played: played)
        if let t = transition {
            driveTransition(t, a: a, played: played)
        } else {
            // B's bake can outlive the transition (slow bake): keep pumping it or B stalls silently.
            if a.bake != nil { pumpBake(a, tau: Double(played + a.startSkip) / a.sampleRate) }
            maybeCommit(a, played: played)
            handleEnd(a, played: played)
        }
        if primary === a, a.beats == nil || a.trimIsFallback { refreshBeats(a) }
        lastAnchor = makeAnchor()
    }

    private func refreshBeats(_ v: Voice) {
        guard !v.refreshingBeats else { return }
        v.refreshingBeats = true
        let id = v.id, track = v.track
        Task {
            let cached = await self.analyzer.cached(track)
            if let v = self.voice(withID: id) {
                if let beats = cached?.beats { v.beats = beats }
                // Better trim than the untrimmed fallback: adopt it if the body hasn't reached the new end yet.
                if v.trimIsFallback, let trim = cached?.trim {
                    v.trimIsFallback = false
                    if v.bodyNext + Int64(3 * v.sampleRate) < trim.endFrame, v.bodyLimit <= trim.endFrame { v.trim = trim }
                }
            }
            // Retry later if still unknown.
            try? await Task.sleep(for: .seconds(2))
            self.voice(withID: id)?.refreshingBeats = false
        }
    }

    func voice(withID id: Int) -> Voice? {
        if let p = primary, p.id == id { return p }
        if let b = transition?.b, b.id == id { return b }
        return fading.first { $0.id == id }
    }

    // MARK: Raw body

    func hasNextTrack(_ v: Voice) -> Bool {
        guard let p = orderPosition(of: v) else { return false }
        return order[(p + 1)...].contains { tracks.indices.contains($0) && !unplayableIDs.contains(tracks[$0].id) }
    }

    func preLimitFrame(_ v: Voice) -> Int64 {
        let l = v.trim.durationSeconds
        let tNom = max(min(settings.seconds, l / 2), TransitionPlanner.minSeconds)
        return v.trim.endFrame - Int64((1.05 * tNom + Tuning.preLimitMarginSeconds) * v.sampleRate)
    }

    /// Frame up to which raw body may be scheduled, and whether it ends with the final fade-out.
    private func desiredBodyLimit(_ v: Voice, played: Int64) -> (limit: Int64, final: Bool) {
        if v === primary, let t = transition { return (t.plan.aStartFrame, false) }
        let pos = Int64(v.sourceFrame(atSample: played) ?? Double(v.bodyNext))
        return Self.bodyLimit(trimStart: v.trim.startFrame, trimEnd: v.trim.endFrame, sampleRate: v.sampleRate, position: pos,
                              preLimit: preLimitFrame(v), noTransition: v.noTransition, hasNext: hasNextTrack(v),
                              commitRunning: commitTask != nil)
    }

    /// Pure body-limit rule (no transition committed). Once the 8 s floor passes the final limit with nothing
    /// committed or being committed, the voice must take the final fade path or it would never finish.
    nonisolated static func bodyLimit(trimStart: Int64, trimEnd: Int64, sampleRate sr: Double, position pos: Int64, preLimit: Int64,
                                      noTransition: Bool, hasNext: Bool, commitRunning: Bool) -> (limit: Int64, final: Bool) {
        let finalLimit = max(trimEnd - Int64(Tuning.endFade * sr), trimStart)
        if noTransition || !hasNext { return (finalLimit, true) }
        let floor = pos + Int64(8 * sr)
        let limit = min(max(preLimit, floor), finalLimit)
        return (limit, limit >= finalLimit && !commitRunning)
    }

    func topUpBody(_ v: Voice, played: Int64) {
        guard v.alive, v.bodyEnabled, !v.finished else { return }
        let (limit, final) = desiredBodyLimit(v, played: played)
        v.bodyLimit = limit
        scheduleDecodedBody(v)
        requestBodyRead(v, played: played)
        if final, v.bodyNext >= v.bodyLimit {
            let count = Int(max(v.trim.endFrame - v.bodyNext, 0))
            if count > 0, let buf = v.readRamp(start: v.bodyNext, count: count, gain: { Float(cos(Double.pi / 2 * $0)) }) {
                v.scheduleRaw(buf, src: v.bodyNext)
            }
            v.finished = true
        }
    }

    /// Moves decoded body chunks onto the node (they are in memory, so scheduling them early is free), up to the limit.
    private func scheduleDecodedBody(_ v: Voice) {
        while v.bodyNext < v.bodyLimit, let c = v.bodyReady.first {
            v.bodyReady.removeFirst()
            guard c.src == v.bodyNext else { v.bodyReady.removeAll(); break } // stale (cursor moved)
            c.buffer.frameLength = AVAudioFrameCount(min(Int64(c.buffer.frameLength), v.bodyLimit - c.src))
            v.scheduleRaw(c.buffer, src: c.src)
        }
    }

    /// Decodes the next body chunk in the background while less than `bodyAheadSeconds` is decoded ahead.
    private func requestBodyRead(_ v: Voice, played: Int64) {
        guard !v.bodyReadInFlight else { return }
        let start = v.bodyReady.last?.end ?? v.bodyNext
        let buffered = v.ahead(of: played) + (start - v.bodyNext)
        guard start < v.bodyLimit, buffered < Int64(Tuning.bodyAheadSeconds * v.sampleRate) else { return }
        let count = Int(min(Int64(Tuning.bodyChunkSeconds * v.sampleRate), v.bodyLimit - start))
        v.bodyReadInFlight = true
        let reader = v.bodyReader, id = v.id
        Task {
            let chunk = await Task.detached(priority: .userInitiated) { reader.read(start: start, count: count) }.value
            guard let v = self.voice(withID: id), v.alive else { return }
            v.bodyReadInFlight = false
            if let chunk, start == (v.bodyReady.last?.end ?? v.bodyNext), let buf = TransitionBaker.makeBuffer(chunk, format: v.format) {
                v.bodyReady.append(Voice.BodyChunk(buffer: buf, src: start))
            } else if chunk == nil {
                self.log.error("body read failed for \(v.track.fileName, privacy: .public)")
            }
            if v.started, self.state == .playing { self.topUpBody(v, played: v.playedSamples() ?? 0) }
        }
    }

    /// Track is on its final fade with no committed transition: start the next one with a plain crossfade shortly
    /// before the end (or once it ran out), or stop at the end of the order.
    private func handleEnd(_ a: Voice, played: Int64) {
        guard a.finished, a.scheduledEnd > 0, loadingTarget == nil else { return }
        let ranOut = played >= a.scheduledEnd
        guard let p = orderPosition(of: a), hasNextTrack(a) else {
            if ranOut { stop() }
            return
        }
        if ranOut {
            retireCurrent(fade: 0)
            beginLoading(position: p + 1, step: 1)
            return
        }
        let src = a.sourceFrame(atSample: played) ?? Double(a.bodyNext)
        if (Double(a.trim.endFrame) - src) / a.sampleRate <= Tuning.quickFade + 0.7 {
            beginLoading(position: p + 1, step: 1) // beginBody crossfades the still-playing voice out
        }
    }

    // MARK: Commit

    func cancelCommit() {
        commitToken += 1
        commitTask?.cancel()
        commitTask = nil
    }

    private func maybeCommit(_ a: Voice, played: Int64) {
        guard commitTask == nil, !a.noTransition, !a.finished, hasNextTrack(a) else { return }
        let src = Int64(a.sourceFrame(atSample: played) ?? Double(a.bodyNext))
        guard src >= preLimitFrame(a) - Int64(Tuning.commitLeadSeconds * a.sampleRate) else { return }
        commitToken += 1
        let token = commitToken
        commitTask = Task { await self.commit(a, token: token) }
    }

    private func commitValid(_ a: Voice, _ token: Int) -> Bool {
        token == commitToken && a.alive && primary === a && transition == nil && state == .playing
    }

    private func commit(_ a: Voice, token: Int) async {
        defer { if token == commitToken { commitTask = nil } }
        guard let startPos = orderPosition(of: a) else { return }

        // 1. Next playable track + its analysis (bounded wait; fallback = untrimmed, no beats).
        var pos = startPos + 1
        var chosen: (track: Track, analysis: TrackAnalysis?)?
        while order.indices.contains(pos), tracks.indices.contains(order[pos]) {
            let track = tracks[order[pos]]
            if unplayableIDs.contains(track.id) { pos += 1; continue }
            let analyzer = self.analyzer
            var an = await withTimeout(seconds: Tuning.analysisTimeout) { await analyzer.analysis(for: track, priority: .userInitiated) }
            guard commitValid(a, token) else { return }
            if an == nil {
                // Timed out: quick trim-only scan instead of playing untrimmed (beats arrive later, if at all).
                let url = track.url
                let quick = await Task.detached(priority: .userInitiated) { () -> TrimInfo?? in
                    do { return .some(try SilenceDetector.detect(url: url)) } catch { return nil }
                }.value
                guard commitValid(a, token) else { return }
                if case .some(let trim) = quick { an = TrackAnalysis(trim: trim, beats: nil) }
            }
            if let an, an.trim == nil { unplayableIDs.insert(track.id); pos += 1; continue }
            chosen = (track, an)
            break
        }
        guard let chosen else { a.noTransition = true; return }

        // 2. Make sure A's beats are known (it was analysed when it started; usually cached by now).
        if a.beats == nil {
            let analyzer = self.analyzer
            let track = a.track
            let cached = await analyzer.cached(track)
            guard commitValid(a, token) else { return }
            a.beats = cached?.beats
            if cached == nil, let an = await withTimeout(seconds: 3, { await analyzer.analysis(for: track, priority: .userInitiated) }) {
                guard commitValid(a, token) else { return }
                a.beats = an.beats
            }
        }
        guard orderPosition(of: a) == startPos, order.indices.contains(pos), tracks[order[pos]].id == chosen.track.id, !a.finished else {
            return // order changed meanwhile; tick retries with the new order
        }

        // 3. Build B and the plan; everything below is synchronous (A's cursor cannot move under us).
        let b: Voice
        do {
            b = try Voice(track: chosen.track, analysis: chosen.analysis)
        } catch {
            unplayableIDs.insert(chosen.track.id)
            return
        }
        // Leave B's first bake chunk time to finish before A reaches the baked region.
        let srcNow = Int64(a.sourceFrame(atSample: a.playedSamples() ?? 0) ?? Double(a.bodyNext))
        let earliest = max(a.bodyNext, srcNow + Int64(Tuning.bakeLeadSeconds * a.sampleRate))
        let plan = TransitionPlanner.plan(a: .init(trim: a.trim, beats: a.beats), b: .init(trim: b.trim, beats: b.beats),
                                          requestedSeconds: settings.seconds, aEarliestStartFrame: earliest)
        guard plan.aStartFrame >= earliest, plan.duration >= Self.minViableTransition else {
            // Too little of A left for a transition: finish A with a fade and let handleEnd crossfade into B.
            log.info("no viable transition for \(a.track.fileName, privacy: .public); plain crossfade")
            a.noTransition = true
            return
        }
        a.bodyLimit = plan.aStartFrame
        let aBase = a.scheduledEnd + (plan.aStartFrame - a.bodyNext)
        a.bake = Voice.BakeJob(plan: plan, side: .outgoing, total: plan.framesA, doneThrough: 0, baseSample: aBase)
        b.bake = Voice.BakeJob(plan: plan, side: .incoming, total: plan.framesB, doneThrough: 0, baseSample: 0)
        b.bodyEnabled = false
        attach(b)
        transition = ActiveTransition(plan: plan, b: b, aBase: aBase)
        kickPrefetch(from: pos)
        let desc = plan.beatMatched
            ? String(format: "beatmatched %.1f->%.1f BPM (fold x%g)", plan.bpmA ?? 0, (plan.bpmB ?? 0) * plan.foldFactor, plan.foldFactor)
            : "EQ only"
        log.info("transition committed: \(a.track.fileName, privacy: .public) -> \(b.track.fileName, privacy: .public) T=\(plan.duration, format: .fixed(precision: 1))s \(desc, privacy: .public)")
    }

    // MARK: Drive

    func driveTransition(_ t: ActiveTransition, a: Voice, played: Int64) {
        let plan = t.plan
        let b = t.b
        let tau = Double(played - t.aBase) / a.sampleRate
        pumpBake(a, tau: tau)
        pumpBake(b, tau: tau)

        if !b.started, !b.ready.isEmpty, tau >= -Tuning.startLeadSeconds { startIncoming(b, t: t, a: a, tau: tau) }
        if b.started { topUpBody(b, played: b.playedSamples() ?? 0) }
        #if DEBUG
        debugMeasureAlignment(t, a: a)
        #endif
        if played >= t.aBase + plan.framesA { finishTransition(a: a, t) }
    }

    /// Starts B so its output frame 0 lines up with A's first baked sample. On time: `play(at:)` the A-derived host
    /// time. Late (A already past it): start a little ahead and drop the head frames B would have played by then,
    /// so B's timeline stays locked to A's instead of flamming the whole transition.
    private func startIncoming(_ b: Voice, t: ActiveTransition, a: Voice, tau: Double) {
        let when0 = clock.renderTime(ofSample: t.aBase, node: a.node, sampleRate: a.sampleRate)
        if tau < -0.02 {
            guard let when0 else { return } // A's render clock not available yet: retry next tick
            for c in b.ready { b.scheduleBaked(c.buffer, side: .incoming, plan: t.plan, firstOut: c.firstOut) }
            b.ready.removeAll()
            b.started = true
            b.node.play(at: when0)
            return
        }
        let when = clock.time(afterSeconds: Tuning.lateStartLeadSeconds)
        let elapsed = when0.map { clock.seconds(from: $0, to: when) } ?? (tau + Tuning.lateStartLeadSeconds)
        var skip = Int64((max(elapsed, 0) * t.plan.srB).rounded(.up))
        log.warning("incoming voice started late (tau=\(tau, format: .fixed(precision: 3)), skipping \(skip) frames)")
        let total = b.ready.reduce(Int64(0)) { $0 + Int64($1.buffer.frameLength) }
        if skip >= total { skip = max(total - 1, 0) } // hopelessly late: unsynchronised start beats silence
        let startSkip = skip
        for c in b.ready {
            let n = Int64(c.buffer.frameLength)
            if skip >= n { skip -= n; continue }
            if let buf = skip > 0 ? Self.droppingHead(c.buffer, frames: Int(skip)) : c.buffer {
                b.scheduleBaked(buf, side: .incoming, plan: t.plan, firstOut: c.firstOut + skip)
            }
            skip = 0
        }
        b.ready.removeAll()
        b.startSkip = startSkip
        b.started = true
        b.node.play(at: when)
    }

    static func droppingHead(_ src: AVAudioPCMBuffer, frames drop: Int) -> AVAudioPCMBuffer? {
        let n = Int(src.frameLength) - drop
        guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: AVAudioFrameCount(n)),
              let s = src.floatChannelData, let d = out.floatChannelData else { return nil }
        for c in 0..<Int(src.format.channelCount) { memcpy(d[c], s[c] + drop, n * MemoryLayout<Float>.size) }
        out.frameLength = AVAudioFrameCount(n)
        return out
    }

    private func finishTransition(a: Voice, _ t: ActiveTransition) {
        let b = t.b
        detach(a)
        primary = b
        transition = nil
        if let p = orderPosition(of: b) { kickPrefetch(from: p) }
    }

    // MARK: Bake pump

    /// Schedules finished chunks (in order) and requests the next one while the baked end is < 8 s ahead of
    /// the playhead (`tau`, output time; negative before the transition starts).
    func pumpBake(_ v: Voice, tau: Double) {
        guard var job = v.bake else { return }
        let sr = job.plan.sampleRate(job.side)
        // B's chunks are held back until B starts (a late start trims the first one).
        let eligible = job.side == .incoming ? v.started : v.bodyNext >= v.bodyLimit
        if eligible, !v.ready.isEmpty {
            for c in v.ready { v.scheduleBaked(c.buffer, side: job.side, plan: job.plan, firstOut: c.firstOut) }
            v.ready.removeAll()
        }
        if job.doneThrough >= job.total, v.ready.isEmpty, !job.inFlight {
            v.bake = nil
            if job.side == .incoming {
                v.bodyNext = job.plan.bEndFrame
                v.bodyEnabled = true
            }
            return
        }
        guard !job.inFlight, job.doneThrough < job.total, v.ready.count < 2,
              Double(job.doneThrough) / sr - tau < Tuning.bakeAheadSeconds else { return }
        let j0 = job.doneThrough
        let j1 = min(j0 + Int64(Tuning.bakeChunkSeconds * sr), job.total)
        job.inFlight = true
        v.bake = job
        let url = v.track.url, plan = job.plan, side = job.side, id = v.id
        Task {
            let chunk = await Task.detached(priority: .userInitiated) { try? TransitionBaker.bake(url: url, plan: plan, side: side, frames: j0..<j1) }.value
            if let v = self.voice(withID: id) { self.bakeFinished(v, j0: j0, j1: j1, chunk: chunk) }
        }
    }

    private func bakeFinished(_ v: Voice, j0: Int64, j1: Int64, chunk: [[Float]]?) {
        guard v.alive, var job = v.bake, job.inFlight, job.doneThrough == j0 else { return }
        let channels = chunk ?? [[Float]](repeating: [Float](repeating: 0, count: Int(j1 - j0)), count: Int(v.format.channelCount))
        if chunk == nil { log.error("bake failed for \(v.track.fileName, privacy: .public)") }
        if let buf = TransitionBaker.makeBuffer(channels, format: v.format) {
            v.ready.append(Voice.ReadyChunk(buffer: buf, firstOut: j0))
        }
        job.doneThrough = j1
        job.inFlight = false
        v.bake = job
    }

    // MARK: Mid-transition rebuild (resume / device change)

    func rebuildTransition(plan: TransitionPlan, a ta: Track, aAnalysis: TrackAnalysis, b tb: Track, bAnalysis: TrackAnalysis,
                           tau: Double, epoch e: Int) async {
        let j0A = Int64((tau * plan.srA).rounded()), j0B = Int64((tau * plan.srB).rounded())
        let j1A = min(j0A + Int64(Tuning.bakeChunkSeconds * plan.srA), plan.framesA)
        let j1B = min(j0B + Int64(Tuning.bakeChunkSeconds * plan.srB), plan.framesB)
        let urlA = ta.url, urlB = tb.url
        async let chunkA = Task.detached(priority: .userInitiated) { try? TransitionBaker.bake(url: urlA, plan: plan, side: .outgoing, frames: j0A..<j1A) }.value
        async let chunkB = Task.detached(priority: .userInitiated) { try? TransitionBaker.bake(url: urlB, plan: plan, side: .incoming, frames: j0B..<j1B) }.value
        let (ca, cb) = await (chunkA, chunkB)
        guard e == epoch else { return }
        if state == .paused {
            // Paused while baking: keep the anchor so resume/seek still work.
            pausedAnchor = .transition(plan: plan, a: ta, aAnalysis: aAnalysis, b: tb, bAnalysis: bAnalysis, tau: tau)
            return
        }
        guard state == .playing else { return }
        do {
            guard var ca, var cb else { throw TransitionBaker.BakeError.unreadable }
            let a = try Voice(track: ta, analysis: aAnalysis)
            let b = try Voice(track: tb, analysis: bAnalysis)
            try ensureEngineRunning()
            avEngine.mainMixerNode.outputVolume = 1
            // 30 ms linear fade-in of the first chunk (the pause ramp took the output to silence).
            for (voice, side) in [(a, TransitionSide.outgoing), (b, .incoming)] {
                let n = Int(Tuning.pauseFade * voice.sampleRate)
                for c in 0..<(side == .outgoing ? ca.count : cb.count) {
                    for i in 0..<min(n, side == .outgoing ? ca[c].count : cb[c].count) {
                        let g = Float(i) / Float(n)
                        if side == .outgoing { ca[c][i] *= g } else { cb[c][i] *= g }
                    }
                }
            }
            guard let bufA = TransitionBaker.makeBuffer(ca, format: a.format), let bufB = TransitionBaker.makeBuffer(cb, format: b.format) else {
                throw TransitionBaker.BakeError.unreadable
            }
            attach(a)
            attach(b)
            a.scheduleBaked(bufA, side: .outgoing, plan: plan, firstOut: j0A)
            b.scheduleBaked(bufB, side: .incoming, plan: plan, firstOut: j0B)
            a.bodyNext = plan.aStartFrame
            a.bodyLimit = plan.aStartFrame
            a.bodyEnabled = false
            let aBase = -j0A
            a.bake = Voice.BakeJob(plan: plan, side: .outgoing, total: plan.framesA, doneThrough: j1A, baseSample: aBase)
            b.bake = Voice.BakeJob(plan: plan, side: .incoming, total: plan.framesB, doneThrough: j1B, baseSample: -j0B)
            b.bodyEnabled = false
            retireCurrent(fade: 0)
            primary = a
            transition = ActiveTransition(plan: plan, b: b, aBase: aBase)
            loadingTarget = nil
            heldTelemetry = nil
            let when = clock.time(afterSeconds: 0.1)
            a.started = true
            b.started = true
            a.node.play(at: when)
            b.node.play(at: when)
            startTick()
        } catch {
            log.error("mid-transition rebuild failed: \(error.localizedDescription, privacy: .public)")
            // Fall back to the dominant track only.
            let domB = tau / plan.duration > 0.5
            let track = domB ? tb : ta
            let an = domB ? bAnalysis : aAnalysis
            let frame = Int64(max(plan.sourcePosition(domB ? .incoming : .outgoing, atFrame: Int64(tau * plan.sampleRate(domB ? .incoming : .outgoing))), 0))
            do {
                try beginBody(track: track, analysis: an, frame: frame, fadeIn: Tuning.pauseFade, fadeOutOld: 0)
            } catch {
                log.error("rebuild fallback failed: \(error.localizedDescription, privacy: .public)")
                stop()
            }
        }
    }
}

#if DEBUG
extension PlaybackEngine {
    /// Estimates how far B's output lags A's (milliseconds, + = B late) using each node's own render timestamp
    /// projected to a common host time. nil until both render.
    func debugMeasureAlignment(_ t: ActiveTransition, a: Voice) {
        guard t.b.started,
              let na = a.node.lastRenderTime, let pa = a.node.playerTime(forNodeTime: na),
              let nb = t.b.node.lastRenderTime, let pb = t.b.node.playerTime(forNodeTime: nb),
              na.isHostTimeValid, nb.isHostTimeValid, pb.sampleTime > 0 else { return }
        let h = max(na.hostTime, nb.hostTime)
        let tauA = Double(pa.sampleTime - t.aBase) / a.sampleRate + AVAudioTime.seconds(forHostTime: h) - AVAudioTime.seconds(forHostTime: na.hostTime)
        let tauB = Double(pb.sampleTime + t.b.startSkip) / t.b.sampleRate + AVAudioTime.seconds(forHostTime: h) - AVAudioTime.seconds(forHostTime: nb.hostTime)
        debugAlignmentMs = (tauB - tauA) * 1000
    }
}
#endif
