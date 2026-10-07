import SwiftUI

struct ContentView: View {
    @Environment(PlayerViewModel.self) private var model

    var body: some View {
        Group {
            if model.folderName == nil {
                ContentUnavailableView {
                    Label("Choose a music folder", systemImage: "music.note.house")
                } description: {
                    Text("All audio files inside, including subfolders, play in a row with long beatmatched transitions.")
                } actions: {
                    Button("Choose Folder…") { model.chooseFolder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    NowPlayingView()
                        .padding(.horizontal, 20).padding(.vertical, 16)
                    HStack(spacing: 24) {
                        TransportBar()
                        Spacer(minLength: 0)
                        SettingsBar()
                    }
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    Divider()
                    TrackListView()
                }
            }
        }
        .background(.background)
        .task { await model.start() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            Text(model.folderName ?? "").font(.headline).lineLimit(1)
            Button("Choose Folder…") { model.chooseFolder() }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").foregroundStyle(.secondary)
            } else {
                Text("^[\(model.tracks.count) track](inflect: true)").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }
}
