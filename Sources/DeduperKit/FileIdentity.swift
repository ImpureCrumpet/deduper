import Foundation

/// Physical file identity using filesystem resource identifiers.
/// Complements PathIdentity (string canonicalization) with inode-level
/// checks for hard links and aliases.
///
/// **Semantics of `nil`**: `nil` means "identity could not be
/// determined" — missing file, permissions, sandbox scope, network
/// filesystem, or unavailable volume identifier. Callers MUST treat
/// `nil` as fail-open (proceed without warning) unless the product
/// decision explicitly changes to fail-closed. This is intentional:
/// `samePhysicalFile` is a best-effort diagnostic, not a safety gate.
public enum FileIdentity {

    /// Resolved resource identifiers for a single file.
    /// Compute once per keeper, then compare against each candidate.
    /// `@unchecked Sendable` because the contained NSObjects are
    /// immutable opaque identifiers from the filesystem.
    public struct ResolvedIdentity: @unchecked Sendable {
        let fileId: NSObject
        let volumeId: NSObject
    }

    /// Resolve the physical identity of a URL.
    /// Returns nil if the file doesn't exist, is inaccessible,
    /// or volume/file identifiers are unavailable.
    public static func resolve(_ url: URL) -> ResolvedIdentity? {
        let resolved = url.standardizedFileURL
            .resolvingSymlinksInPath()

        let keys: Set<URLResourceKey> = [
            .fileResourceIdentifierKey, .volumeIdentifierKey
        ]
        guard
            let vals = try? resolved.resourceValues(forKeys: keys),
            let fileId = vals.fileResourceIdentifier as? NSObject,
            let volumeId = vals.volumeIdentifier as? NSObject
        else { return nil }

        return ResolvedIdentity(fileId: fileId, volumeId: volumeId)
    }

    /// Returns true if both URLs resolve to the same underlying
    /// filesystem object (same inode on same volume).
    /// Returns nil if identity cannot be determined for either URL.
    public static func samePhysicalFile(
        _ a: URL, _ b: URL
    ) -> Bool? {
        guard let aId = resolve(a), let bId = resolve(b)
        else { return nil }
        return same(aId, bId)
    }

    /// Compare two pre-resolved identities.
    public static func same(
        _ a: ResolvedIdentity, _ b: ResolvedIdentity
    ) -> Bool {
        a.volumeId.isEqual(b.volumeId) && a.fileId.isEqual(b.fileId)
    }
}
