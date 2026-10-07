import SwiftUI

func formatTime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

struct NowPlayingView: View {
    @Environment(PlayerViewModel.self) private var model
    @State private var dragFraction: Double?

    var body: some View {
        let snap = model.snapshot
        let track = model.snapshotTrack
        let fraction = snap.duration > 0 ? min(max(snap.position / snap.duration, 0), 1) : 0
        let shown = dragFraction ?? fraction
        let bpm = snap.currentBPM ?? track.flatMap { model.bpm[$0.id] }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.map(model.title(for:)) ?? "Nothing playing")
                        .font(.title2.weight(.semibold)).lineLimit(1)
                    Text(track.flatMap(model.artist(for:)) ?? (track == nil ? "Press play or double-click a track" : " "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if snap.inTransition {
                    HStack(spacing: 6) {
                        Text("Mixing…").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: snap.transitionProgress).frame(width: 90)
                    }
                    .transition(.opacity)
                }
                if let bpm {
                    Text(String(format: "%.1f BPM", bpm))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .contentTransition(.numericText())
                }
            }
            .animation(.default, value: snap.inTransition)

            VStack(spacing: 2) {
                Slider(value: Binding(get: { shown }, set: { dragFraction = $0 }), in: 0...1) { editing in
                    if !editing, let f = dragFraction {
                        model.seek(fraction: f)
                        // Hold the thumb briefly so it doesn't snap back before the engine catches up.
                        Task { try? await Task.sleep(for: .milliseconds(200)); dragFraction = nil }
                    }
                }
                .controlSize(.small)
                .disabled(snap.duration <= 0)
                HStack {
                    Text(formatTime(shown * snap.duration))
                    Spacer()
                    Text("−" + formatTime((1 - shown) * snap.duration))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
