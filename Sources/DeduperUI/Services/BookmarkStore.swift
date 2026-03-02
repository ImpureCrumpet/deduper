import Foundation
import DeduperKit

/// Stores security-scoped bookmarks for user-selected directories.
/// Works in non-sandboxed mode today; becomes mandatory if sandboxed.
public enum BookmarkStore {
    private static let key = "deduper.directoryBookmarks"

    /// Save a bookmark for a URL. Returns the bookmark data.
    public static func save(url: URL) throws -> Data {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var bookmarks = loadAll()
        let canonical = PathIdentity.canonical(url)
        bookmarks[canonical] = data
        // Remove legacy raw-path entry if different from canonical
        let raw = url.path
        if raw != canonical {
            bookmarks.removeValue(forKey: raw)
        }
        UserDefaults.standard.set(bookmarks, forKey: key)

        return data
    }

    /// Resolve a saved bookmark back to a URL.
    /// Starts security-scoped access if needed.
    public static func resolve(
        bookmarkData: Data
    ) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            // Re-save the bookmark
            _ = try save(url: url)
        }

        return url
    }

    /// Load all saved bookmark data, keyed by original path.
    public static func loadAll() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: key)?
            .compactMapValues { $0 as? Data } ?? [:]
    }

    /// Save bookmarks for multiple URLs.
    public static func saveAll(urls: [URL]) {
        for url in urls {
            _ = try? save(url: url)
        }
    }
}
