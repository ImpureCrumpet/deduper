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

    /// Look up bookmark data for a URL. Tries canonical key first,
    /// then falls back to raw path for legacy entries. Migrates
    /// legacy keys to canonical on hit.
    public static func bookmark(for url: URL) -> Data? {
        var bookmarks = loadAll()
        let canonical = PathIdentity.canonical(url)

        if let data = bookmarks[canonical] { return data }

        // Legacy fallback: raw path
        let raw = url.path
        if raw != canonical, let data = bookmarks[raw] {
            // Migrate to canonical key
            bookmarks[canonical] = data
            bookmarks.removeValue(forKey: raw)
            UserDefaults.standard.set(bookmarks, forKey: key)
            return data
        }

        return nil
    }

    /// Load all saved bookmark data, keyed by path.
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
