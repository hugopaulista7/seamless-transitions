import Foundation
import UniformTypeIdentifiers

/// Recursively finds audio files under a root folder.
enum FolderScanner {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "flac", "alac", "caf", "m4b", "mp4"]
    private static let playlistExtensions: Set<String> = ["m3u", "m3u8", "pls", "cue", "xspf"]

    /// Scans `root` recursively; result sorted by relative path (Finder-style).
    static func scan(_ root: URL) throws -> [Track] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadUnknown) }
        var tracks: [Track] = []
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if playlistExtensions.contains(ext) { continue }
            let isAudio = values?.contentType?.conforms(to: .audio) == true || audioExtensions.contains(ext)
            if isAudio { tracks.append(Track(url: url, root: root)) }
        }
        return tracks.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
