import Testing
import Foundation
@testable import DeduperUI
@testable import DeduperKit

@Suite("BookmarkStore")
struct BookmarkStoreTests {

    /// Unique UserDefaults key used by BookmarkStore.
    private static let key = "deduper.directoryBookmarks"

    /// Clean up test state from UserDefaults.
    private func cleanup() {
        UserDefaults.standard.removeObject(
            forKey: BookmarkStoreTests.key
        )
    }

    @Test("bookmark(for:) migrates legacy raw-path key to canonical")
    func migratesLegacyKey() throws {
        defer { cleanup() }
        cleanup()

        // Create a real directory and a symlink to it so that
        // canonical (symlink-resolved) path differs from the
        // raw symlink path.
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".deduper-bm-test-\(UUID().uuidString)"
            )
        let realDir = base.appendingPathComponent("real")
        try fm.createDirectory(
            at: realDir, withIntermediateDirectories: true
        )
        defer { try? fm.removeItem(at: base) }

        let linkPath = base.appendingPathComponent("link")
        try fm.createSymbolicLink(
            at: linkPath, withDestinationURL: realDir
        )

        let symlinkURL = linkPath
        let rawPath = symlinkURL.path
        let canonical = PathIdentity.canonical(symlinkURL)

        // Pre-condition: symlink path differs from resolved
        #expect(rawPath != canonical,
                "Symlink should differ from canonical")

        let fakeBookmark = Data("fake-bookmark-data".utf8)

        // Seed legacy entry under the raw (symlink) path
        UserDefaults.standard.set(
            [rawPath: fakeBookmark],
            forKey: BookmarkStoreTests.key
        )

        // Look up — should find via legacy fallback and migrate
        let result = BookmarkStore.bookmark(for: symlinkURL)

        #expect(result == fakeBookmark)

        // After lookup, canonical key present, raw key removed
        let all = BookmarkStore.loadAll()
        #expect(all[canonical] == fakeBookmark)
        #expect(all[rawPath] == nil)
    }

    @Test("bookmark(for:) returns canonical key directly when present")
    func findsCanonicalKey() {
        defer { cleanup() }
        cleanup()

        let path = "/tmp/test-dir"
        let canonical = PathIdentity.canonical(path)
        let fakeBookmark = Data("canonical-bookmark".utf8)

        UserDefaults.standard.set(
            [canonical: fakeBookmark],
            forKey: BookmarkStoreTests.key
        )

        let url = URL(fileURLWithPath: path)
        let result = BookmarkStore.bookmark(for: url)

        #expect(result == fakeBookmark)

        // No migration needed — store unchanged
        let all = BookmarkStore.loadAll()
        #expect(all.count == 1)
        #expect(all[canonical] == fakeBookmark)
    }

    @Test("bookmark(for:) returns nil when no entry exists")
    func returnsNilForMissing() {
        defer { cleanup() }
        cleanup()

        let url = URL(fileURLWithPath: "/tmp/nonexistent-dir")
        let result = BookmarkStore.bookmark(for: url)
        #expect(result == nil)
    }
}
