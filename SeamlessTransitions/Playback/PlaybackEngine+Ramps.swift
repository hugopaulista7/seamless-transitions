import Foundation

/// Timer-driven volume ramps (pause/seek/skip fades). Steps every 1 ms for short ramps, 5 ms for long ones.
extension PlaybackEngine {
    @discardableResult
    func startRamp(duration: Double, apply: @escaping (Double) -> Void, completion: ((isolated PlaybackEngine) -> Void)? = nil) -> Int {
        rampCounter += 1
        let r = Ramp(id: rampCounter, start: ProcessInfo.processInfo.systemUptime, duration: max(duration, 0.001),
                     apply: apply, completion: completion)
        ramps.append(r)
        apply(0)
        armRampTimer()
        return r.id
    }

    func cancelRamp(_ id: Int?) {
        guard let id else { return }
        ramps.removeAll { $0.id == id }
        if ramps.isEmpty { disarmRampTimer() }
    }

    private func armRampTimer() {
        let interval = ramps.contains { $0.duration < 0.1 } ? 0.001 : 0.005
        if rampTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.assumeIsolated { $0.stepRamps() }
            }
            rampTimer = t
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(100))
            t.resume()
        } else {
            rampTimer?.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(100))
        }
    }

    private func disarmRampTimer() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    private func stepRamps() {
        let now = ProcessInfo.processInfo.systemUptime
        var finished: [Ramp] = []
        for r in ramps {
            let u = min(max((now - r.start) / r.duration, 0), 1)
            r.apply(u)
            if u >= 1 { finished.append(r) }
        }
        guard !finished.isEmpty else { return }
        let ids = Set(finished.map(\.id))
        ramps.removeAll { ids.contains($0.id) }
        if ramps.isEmpty { disarmRampTimer() }
        for r in finished { r.completion?(self) }
    }

    func cancelAllRamps() {
        ramps.removeAll()
        disarmRampTimer()
    }
}
