import SwiftUI

struct TrackListView: View {
    @Environment(PlayerViewModel.self) private var model
    /// Track indices selected in the list (click highlights; double-click / Return plays).
    @State private var selection: Set<Int> = []

    var body: some View {
        let currentID = model.currentTrack?.id
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(Array(model.order.order.enumerated()), id: \.element) { pos, idx in
                        if model.tracks.indices.contains(idx) {
                            let t = model.tracks[idx]
                            TrackRow(
                                number: pos + 1, track: t,
                                title: model.title(for: t), artist: model.artist(for: t),
                                bpm: model.bpm[t.id],
                                isCurrent: t.id == currentID,
                                isPlaying: model.isPlaying && t.id == currentID,
                                isUnplayable: model.unplayable.contains(t.id)
                            )
                            .id(t.id)
                            .listRowBackground(t.id == currentID ? Color.accentColor.opacity(0.14) : nil)
                            .task { await model.loadInfo(for: t) }
                        }
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: Int.self) { ids in
                    if let idx = ids.first {
                        Button("Play") { model.playTrack(index: idx) }
                    }
                } primaryAction: { ids in
                    if let idx = ids.first { model.playTrack(index: idx) }
                }
                .onChange(of: currentID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 32, alignment: .trailing)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            Text("Artist").frame(maxWidth: .infinity, alignment: .leading)
            Text("Folder").frame(maxWidth: .infinity, alignment: .leading)
            Text("BPM").frame(width: 56, alignment: .trailing)
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 24).padding(.vertical, 6)
    }
}

private struct TrackRow: View, Equatable {
    let number: Int
    let track: Track
    let title: String
    let artist: String?
    let bpm: Double?
    let isCurrent: Bool
    let isPlaying: Bool
    let isUnplayable: Bool
    @State private var isHovered = false

    nonisolated static func == (a: TrackRow, b: TrackRow) -> Bool {
        a.number == b.number && a.track == b.track && a.title == b.title && a.artist == b.artist && a.bpm == b.bpm
            && a.isCurrent == b.isCurrent && a.isPlaying == b.isPlaying && a.isUnplayable == b.isUnplayable
    }

    var body: some View {
        let folder = (track.relativePath as NSString).deletingLastPathComponent
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(number)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, alignment: .trailing)
            Text(title).fontWeight(isCurrent ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(artist ?? "").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(folder).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(bpm.map { String(format: "%.1f", $0) } ?? "—")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .lineLimit(1)
        .opacity(isUnplayable ? 0.4 : 1)
        .padding(.vertical, 2)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(isUnplayable ? "Can't be played (silent or unreadable)" : track.relativePath)
    }
}
