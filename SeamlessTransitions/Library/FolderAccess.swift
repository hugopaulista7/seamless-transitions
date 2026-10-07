import Foundation

/// Persists and restores read-only security-scoped access to the user's chosen folder.
@MainActor
final class FolderAccess {
    static let defaultsKey = "lastFolderBookmark"
    private let defaults: UserDefaults
    private var current: URL?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Adopts a freshly chosen folder (e.g. from NSOpenPanel): stops previous access, saves bookmark, starts access.
    func choose(_ url: URL) throws {
        stopAccessing()
        let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.defaultsKey)
        if url.startAccessingSecurityScopedResource() { current = url }
    }

    /// Resolves the saved bookmark and starts access. nil if none / unresolvable.
    func restore() -> URL? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        stopAccessing()
        guard url.startAccessingSecurityScopedResource() else { return nil }
        current = url
        if stale,
           let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                             includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.defaultsKey)
        }
        return url
    }

    /// Ends access to the current folder, if any.
    func stopAccessing() {
        current?.stopAccessingSecurityScopedResource()
        current = nil
    }

    deinit { current?.stopAccessingSecurityScopedResource() }
}
