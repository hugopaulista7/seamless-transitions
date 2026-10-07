import SwiftUI

@main
struct SeamlessTransitionsApp: App {
    @State private var model = PlayerViewModel()

    var body: some Scene {
        Window("SeamlessTransitions", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 860, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {}
            CommandMenu("Playback") {
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!model.hasTracks)
                Button("Next") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!model.hasTracks)
                Button("Previous") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!model.hasTracks)
                Divider()
                Toggle("Shuffle", isOn: Binding(get: { model.shuffle }, set: { model.setShuffle($0) }))
                    .keyboardShortcut("s")
            }
        }
    }
}
