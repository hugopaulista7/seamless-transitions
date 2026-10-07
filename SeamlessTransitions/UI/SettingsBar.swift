import SwiftUI

struct SettingsBar: View {
    @Environment(PlayerViewModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Text("Transition").foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { model.transitionSeconds }, set: { model.setTransitionSeconds($0) }),
                    in: TransitionSettings.range, step: 5
                )
                .frame(width: 160)
                .controlSize(.small)
                Text(formatTime(model.transitionSeconds))
                    .monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            .help("Length of each mix transition")
            Toggle(isOn: Binding(get: { model.shuffle }, set: { model.setShuffle($0) })) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .toggleStyle(.button)
            .help("Shuffle (⌘S)")
        }
    }
}
