import SwiftUI

struct TransportBar: View {
    @Environment(PlayerViewModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            Button { model.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 18))
            }
            .help("Previous (⌘←)")
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            Button { model.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 18))
            }
            .help("Next (⌘→)")
        }
        .buttonStyle(.plain)
        .disabled(!model.hasTracks)
    }
}
