@preconcurrency import AVFoundation

/// Loads and caches display metadata (title/artist) for tracks.
actor MetadataLoader {
    struct Info: Sendable, Hashable {
        var title: String
        var artist: String?
    }

    private var cache: [String: Info] = [:]

    func info(for track: Track) async -> Info {
        if let hit = cache[track.id] { return hit }
        let (title, artist) = await Self.titleAndArtist(url: track.url)
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = Info(title: (t?.isEmpty == false ? t : nil) ?? track.fileName,
                        artist: (a?.isEmpty == false) ? a : nil)
        if Task.isCancelled { return info } // a cancelled load may have failed spuriously: don't cache it
        cache[track.id] = info
        return info
    }

    private static func titleAndArtist(url: URL) async -> (String?, String?) {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return (nil, nil) }
        return (await string(items, .commonIdentifierTitle), await string(items, .commonIdentifierArtist))
    }

    private static func string(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
        return try? await item.load(.stringValue)
    }
}
