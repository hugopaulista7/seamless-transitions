import Foundation

/// One audio file found in the chosen folder tree.
struct Track: Identifiable, Sendable, Hashable, Codable {
    /// Standardized absolute path; stable identity across rescans.
    let id: String
    let url: URL
    /// Path relative to the chosen root folder (used for sorting and display).
    let relativePath: String
    /// File name without extension; fallback title when metadata is missing.
    let fileName: String

    init(url: URL, root: URL) {
        let std = url.standardizedFileURL
        self.id = std.path
        self.url = std
        let rootPath = root.standardizedFileURL.path
        let full = std.path
        if full.hasPrefix(rootPath) {
            self.relativePath = String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            self.relativePath = std.lastPathComponent
        }
        self.fileName = std.deletingPathExtension().lastPathComponent
    }
}
