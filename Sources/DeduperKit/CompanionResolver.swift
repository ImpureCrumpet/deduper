import Foundation
import os

/// Resolves companion/sidecar files for a given media file.
/// Companion files include AAE sidecars, XMP files, THM thumbnails,
/// LRV low-res videos, and Live Photo MOV pairs.
public struct CompanionResolver: Sendable {
    private let logger = Logger(
        subsystem: "app.deduper", category: "companion"
    )

    /// Known sidecar extensions that always accompany their primary file.
    private static let sidecarExtensions: Set<String> = [
        "aae", "xmp", "thm", "lrv"
    ]

    /// Extensions that may form a Live Photo pair with a HEIC/JPG.
    private static let livePhotoVideoExtensions: Set<String> = [
        "mov"
    ]

    private static let livePhotoPrimaryExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg"
    ]

    public init() {}

    /// Resolve all companion files for a given primary media file.
    /// Returns the primary file plus any discovered companions.
    public func resolve(for primaryURL: URL) -> CompanionSet {
        let dir = primaryURL.deletingLastPathComponent()
        let stem = primaryURL.deletingPathExtension().lastPathComponent
        let primaryExt = primaryURL.pathExtension.lowercased()

        var companions: [CompanionFile] = []

        // Stem-match sidecars: same directory, same stem, known extensions
        for ext in Self.sidecarExtensions {
            let candidate = dir
                .appendingPathComponent(stem)
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path),
               candidate != primaryURL {
                companions.append(CompanionFile(
                    url: candidate,
                    relationship: .sidecar(ext)
                ))
            }
        }

        // Live Photo detection: if primary is HEIC/JPG, look for MOV pair
        if Self.livePhotoPrimaryExtensions.contains(primaryExt) {
            for ext in Self.livePhotoVideoExtensions {
                let candidate = dir
                    .appendingPathComponent(stem)
                    .appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    companions.append(CompanionFile(
                        url: candidate,
                        relationship: .livePhotoVideo
                    ))
                }
            }
        }

        // Reverse: if primary is a MOV, check if it's a Live Photo video
        if Self.livePhotoVideoExtensions.contains(primaryExt) {
            for ext in Self.livePhotoPrimaryExtensions {
                let candidate = dir
                    .appendingPathComponent(stem)
                    .appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    companions.append(CompanionFile(
                        url: candidate,
                        relationship: .livePhotoImage
                    ))
                }
            }
        }

        return CompanionSet(
            primary: primaryURL,
            companions: companions
        )
    }

    /// Resolve companions for multiple files, deduplicating results.
    public func resolveAll(
        for urls: [URL]
    ) -> [URL: CompanionSet] {
        var result: [URL: CompanionSet] = [:]
        for url in urls {
            result[url] = resolve(for: url)
        }
        return result
    }
}

// MARK: - CompanionSet

/// A primary media file and its discovered companion files.
public struct CompanionSet: Sendable, Equatable {
    public let primary: URL
    public let companions: [CompanionFile]

    /// All URLs in this set (primary + companions).
    public var allURLs: [URL] {
        [primary] + companions.map(\.url)
    }

    /// Companion URLs only.
    public var companionURLs: [URL] {
        companions.map(\.url)
    }

    public var hasCompanions: Bool {
        !companions.isEmpty
    }
}

// MARK: - CompanionFile

public struct CompanionFile: Sendable, Equatable {
    public let url: URL
    public let relationship: CompanionRelationship
}

public enum CompanionRelationship: Sendable, Equatable {
    case sidecar(String) // extension (aae, xmp, thm, lrv)
    case livePhotoVideo  // MOV paired with HEIC/JPG
    case livePhotoImage  // HEIC/JPG paired with MOV (reverse lookup)
}
