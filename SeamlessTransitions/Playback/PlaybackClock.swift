@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Time source for sample-accurate voice starts.
/// - realtime: host-time based (`play(at:)` with `AVAudioTime(hostTime:)`), derived from a node's `lastRenderTime`.
/// - offline: sample-time based, for AVAudioEngine manual-rendering tests. The harness advances the clock by the
///   number of frames it renders.
final class PlaybackClock: Sendable {
    enum Mode: Sendable {
        case realtime
        case offline(sampleRate: Double)
    }

    let mode: Mode
    private let offlineSample = Mutex<Int64>(0)

    init(mode: Mode = .realtime) { self.mode = mode }

    /// Offline only: tell the clock `frames` more engine frames were rendered.
    func advanceOffline(by frames: Int64) {
        offlineSample.withLock { $0 += frames }
    }

    /// A time `seconds` from now suitable for `play(at:)`.
    func time(afterSeconds seconds: Double) -> AVAudioTime {
        switch mode {
        case .realtime:
            return AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: seconds))
        case .offline(let sr):
            let now = offlineSample.withLock { $0 }
            return AVAudioTime(sampleTime: now + Int64((seconds * sr).rounded()), atRate: sr)
        }
    }

    /// When will player-timeline sample `sample` of `node` (running at `sampleRate`) be rendered?
    /// Derived from the node's last render time so it follows the real device clock.
    func renderTime(ofSample sample: Int64, node: AVAudioPlayerNode, sampleRate: Double) -> AVAudioTime? {
        guard let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        let delta = Double(sample - playerTime.sampleTime) / sampleRate
        switch mode {
        case .realtime:
            guard nodeTime.isHostTimeValid else { return nil }
            let ticks = AVAudioTime.hostTime(forSeconds: abs(delta))
            let host = delta >= 0 ? nodeTime.hostTime &+ ticks : nodeTime.hostTime &- ticks
            return AVAudioTime(hostTime: host)
        case .offline:
            guard nodeTime.isSampleTimeValid else { return nil }
            let engineRate = nodeTime.sampleRate
            return AVAudioTime(sampleTime: nodeTime.sampleTime + Int64((delta * engineRate).rounded()), atRate: engineRate)
        }
    }

    /// Seconds from time `a` to time `b` (both from this clock).
    func seconds(from a: AVAudioTime, to b: AVAudioTime) -> Double {
        switch mode {
        case .realtime:
            let d = AVAudioTime.seconds(forHostTime: max(a.hostTime, b.hostTime) - min(a.hostTime, b.hostTime))
            return b.hostTime >= a.hostTime ? d : -d
        case .offline(let sr):
            return Double(b.sampleTime - a.sampleTime) / sr
        }
    }
}
