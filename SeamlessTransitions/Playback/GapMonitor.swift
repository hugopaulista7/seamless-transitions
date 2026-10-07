#if DEBUG
@preconcurrency import AVFoundation
import Foundation
import Synchronization
import os

/// Debug-only watchdog: taps the main mixer and logs dropouts (RMS < -70 dBFS while playing) and clicks
/// (adjacent-sample jump > 0.5). `log stream --predicate 'category == "GapMonitor"'`.
final class GapMonitor: Sendable {
    static let shared = GapMonitor()

    private struct Shared {
        var playing = false
        var installedOn: ObjectIdentifier?
        var lastSample: Float = 0
        var silentBuffers = 0
    }

    private let state = Mutex(Shared())
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SeamlessTransitions", category: "GapMonitor")

    func setPlaying(_ on: Bool) {
        state.withLock {
            $0.playing = on
            if !on { $0.silentBuffers = 0 }
        }
    }

    /// Idempotent per mixer instance.
    func install(on mixer: AVAudioMixerNode) {
        let id = ObjectIdentifier(mixer)
        let already = state.withLock { s -> Bool in
            if s.installedOn == id { return true }
            s.installedOn = id
            return false
        }
        guard !already else { return }
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [self] buffer, _ in
            analyze(buffer)
        }
    }

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sumSq: Float = 0
        var maxDelta: Float = 0
        let first = state.withLock { $0.lastSample }
        var prev = first
        let ch0 = data[0]
        for i in 0..<n {
            let x = ch0[i]
            sumSq += x * x
            maxDelta = max(maxDelta, abs(x - prev))
            prev = x
        }
        let rms = (sumSq / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-9))
        let (playing, silentRun) = state.withLock { s -> (Bool, Int) in
            s.lastSample = prev
            s.silentBuffers = db < -70 ? s.silentBuffers + 1 : 0
            return (s.playing, s.silentBuffers)
        }
        guard playing else { return }
        // Ignore the first buffers (start-up) and require ~2 consecutive quiet buffers to avoid zero-crossing noise.
        if silentRun == 3 { logger.error("gap: RMS \(db, format: .fixed(precision: 1)) dBFS for \(silentRun) buffers") }
        if maxDelta > 0.5 { logger.error("click: sample delta \(maxDelta, format: .fixed(precision: 3))") }
    }
}
#endif
