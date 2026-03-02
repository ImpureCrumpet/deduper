import Foundation
import UniformTypeIdentifiers

// MARK: - Core Types

/**
 * Media types supported by the deduplication system
 */
public enum MediaType: Int16, CaseIterable, Sendable, Codable {
    case photo = 0
    case video = 1
    case audio = 2

    /// Returns the corresponding UTType for this media type
    public var utType: UTType? {
        switch self {
        case .photo:
            return UTType.image
        case .video:
            return UTType.movie
        case .audio:
            return UTType.audio
        }
    }

    /// Returns file extensions commonly associated with this media type
    public var commonExtensions: [String] {
        switch self {
        case .photo:
            return [
                // Standard formats
                "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp",
                // RAW formats (major camera manufacturers)
                "raw", "cr2", "cr3", "nef", "nrw", "arw", "dng", "orf", "pef", "rw2",
                "sr2", "x3f", "erf", "raf", "dcr", "kdc", "mrw", "mos", "srw", "fff",
                // Additional professional formats
                "psd", "ai", "eps", "svg"
            ]
        case .video:
            return [
                // Standard formats
                "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "3gp", "mts", "m2ts", "ogv",
                // Professional formats
                "prores", "dnxhd", "xdcam", "xavc", "r3d", "ari", "arri"
            ]
        case .audio:
            return [
                // Standard formats
                "mp3", "wav", "aac", "m4a", "flac", "ogg", "oga", "opus",
                // Lossless formats
                "alac", "ape", "wv", "tak", "tta",
                // Professional formats
                "aiff", "aif", "au", "ra", "rm", "wma", "ac3", "dts",
                // Additional formats
                "mpc", "spx", "vorbis", "amr", "3ga"
            ]
        }
    }
}

/**
 * Represents a scanned file with basic metadata
 */
public struct ScannedFile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let mediaType: MediaType
    public let fileSize: Int64
    public let createdAt: Date?
    public let modifiedAt: Date?

    public init(id: UUID = UUID(), url: URL, mediaType: MediaType, fileSize: Int64, createdAt: Date? = nil, modifiedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.mediaType = mediaType
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/**
 * Options for scanning directories
 */
public struct ScanOptions: Equatable, Sendable {
    public let excludes: [ExcludeRule]
    public let followSymlinks: Bool
    public let concurrency: Int
    public let incremental: Bool
    public let incrementalLookbackHours: Double

    public init(
        excludes: [ExcludeRule] = [],
        followSymlinks: Bool = false,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        incremental: Bool = true,
        incrementalLookbackHours: Double = 24.0
    ) {
        self.excludes = excludes
        self.followSymlinks = followSymlinks
        self.concurrency = max(1, min(concurrency, ProcessInfo.processInfo.activeProcessorCount))
        self.incremental = incremental
        self.incrementalLookbackHours = max(0.1, incrementalLookbackHours) // Minimum 6 minutes
    }
}

/**
 * Rules for excluding files or directories from scanning
 */
public struct ExcludeRule: Equatable, Sendable {
    public enum RuleType: Equatable, Sendable {
        case pathPrefix(String)
        case pathSuffix(String)
        case pathContains(String)
        case pathMatches(String) // glob pattern
        case isHidden
        case isSystemBundle
        case isCloudSyncFolder
    }

    public let type: RuleType
    public let description: String

    public init(_ type: RuleType, description: String) {
        self.type = type
        self.description = description
    }

    /// Check if a URL matches this exclusion rule
    public func matches(_ url: URL) -> Bool {
        let path = url.path

        switch type {
        case .pathPrefix(let prefix):
            return path.hasPrefix(prefix)
        case .pathSuffix(let suffix):
            return path.hasSuffix(suffix)
        case .pathContains(let substring):
            return path.contains(substring)
        case .pathMatches(let pattern):
            return url.matches(pattern: pattern)
        case .isHidden:
            return url.lastPathComponent.hasPrefix(".")
        case .isSystemBundle:
            return url.pathExtension == "app" || url.pathExtension == "framework" || url.pathExtension == "bundle"
        case .isCloudSyncFolder:
            return isKnownCloudSyncFolder(url)
        }
    }

    private func isKnownCloudSyncFolder(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("icloud") ||
               path.contains("dropbox") ||
               path.contains("google drive") ||
               path.contains("onedrive") ||
               path.contains("box")
    }
}

/**
 * Events emitted during directory scanning
 */
public enum ScanEvent: Sendable {
    case started(URL)
    case progress(Int)
    case item(ScannedFile)
    case skipped(URL, reason: String)
    case error(String, String) // path, reason
    case finished(ScanMetrics)
}

/**
 * Metrics collected during a scan operation
 */
public struct ScanMetrics: Equatable, CustomStringConvertible, Sendable {
    public let totalFiles: Int
    public let mediaFiles: Int
    public let skippedFiles: Int
    public let errorCount: Int
    public let duration: TimeInterval
    public let averageFilesPerSecond: Double

    public init(totalFiles: Int, mediaFiles: Int, skippedFiles: Int, errorCount: Int, duration: TimeInterval) {
        self.totalFiles = totalFiles
        self.mediaFiles = mediaFiles
        self.skippedFiles = skippedFiles
        self.errorCount = errorCount
        self.duration = duration
        self.averageFilesPerSecond = duration > 0 ? Double(totalFiles) / duration : 0
    }

    public var description: String {
        return "ScanMetrics(totalFiles: \(totalFiles), mediaFiles: \(mediaFiles), skippedFiles: \(skippedFiles), errorCount: \(errorCount), duration: \(String(format: "%.2f", duration))s, avgFilesPerSec: \(String(format: "%.1f", averageFilesPerSecond)))"
    }
}

/**
 * Errors that can occur during file access operations
 */
public enum AccessError: Error, LocalizedError, Sendable {
    case bookmarkResolutionFailed
    case securityScopeAccessDenied
    case pathNotAccessible(URL)
    case permissionDenied(URL)
    case fileNotFound(URL)
    case invalidBookmark(Data)

    public var errorDescription: String? {
        switch self {
        case .bookmarkResolutionFailed:
            return "Failed to resolve security-scoped bookmark"
        case .securityScopeAccessDenied:
            return "Security-scoped access denied"
        case .pathNotAccessible(let url):
            return "Path not accessible: \(url.path)"
        case .permissionDenied(let url):
            return "Permission denied for: \(url.path)"
        case .fileNotFound(let url):
            return "File not found: \(url.path)"
        case .invalidBookmark:
            return "Invalid bookmark data"
        }
    }
}

// MARK: - Extensions

extension URL {
    /// Check if this URL matches a glob pattern
    func matches(pattern: String) -> Bool {
        let path = self.path
        let regex = pattern
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: ".")

        return path.range(of: regex, options: .regularExpression) != nil
    }

    /// Get the file resource identifier for tracking hardlinks
    var fileResourceIdentifier: String? {
        guard let values = try? resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let identifier = values.fileResourceIdentifier else {
            return nil
        }
        return identifier.debugDescription
    }

    /// Check if this is an iCloud placeholder
    var isICloudPlaceholder: Bool {
        guard let values = try? resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]) else {
            return false
        }
        return values.ubiquitousItemDownloadingStatus == .notDownloaded
    }
}

// MARK: - Metadata Types

public struct MediaMetadata: Sendable, Equatable {
    public let fileName: String
    public let fileSize: Int64
    public let mediaType: MediaType
    public let createdAt: Date?
    public let modifiedAt: Date?
    public var dimensions: (width: Int, height: Int)?
    public var captureDate: Date?
    public var cameraModel: String?
    public var gpsLat: Double?
    public var gpsLon: Double?
    public var durationSec: Double?
    public var keywords: [String]?
    public var tags: [String]?
    public var inferredUTType: String?

    public init(
        fileName: String,
        fileSize: Int64,
        mediaType: MediaType,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        dimensions: (width: Int, height: Int)? = nil,
        captureDate: Date? = nil,
        cameraModel: String? = nil,
        gpsLat: Double? = nil,
        gpsLon: Double? = nil,
        durationSec: Double? = nil,
        keywords: [String]? = nil,
        tags: [String]? = nil,
        inferredUTType: String? = nil
    ) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.dimensions = dimensions
        self.captureDate = captureDate
        self.cameraModel = cameraModel
        self.gpsLat = gpsLat
        self.gpsLon = gpsLon
        self.durationSec = durationSec
        self.keywords = keywords
        self.tags = tags
        self.inferredUTType = inferredUTType
    }
}

// MARK: - MediaMetadata Equality & Computed Properties

extension MediaMetadata {
    public static func == (lhs: MediaMetadata, rhs: MediaMetadata) -> Bool {
        let lhsDim = lhs.dimensions.map { ($0.width, $0.height) }
        let rhsDim = rhs.dimensions.map { ($0.width, $0.height) }
        return lhs.fileName == rhs.fileName &&
            lhs.fileSize == rhs.fileSize &&
            lhs.mediaType == rhs.mediaType &&
            lhs.createdAt == rhs.createdAt &&
            lhs.modifiedAt == rhs.modifiedAt &&
            lhsDim?.0 == rhsDim?.0 && lhsDim?.1 == rhsDim?.1 &&
            lhs.captureDate == rhs.captureDate &&
            lhs.cameraModel == rhs.cameraModel &&
            lhs.gpsLat == rhs.gpsLat &&
            lhs.gpsLon == rhs.gpsLon &&
            lhs.durationSec == rhs.durationSec
    }

    /// Calculate metadata completeness score for keeper selection
    public var completenessScore: Double {
        var score = 0.0
        var totalFields = 0

        // Basic file metadata (always available)
        score += 1.0
        totalFields += 1

        // Capture date
        if captureDate != nil { score += 1.0 }
        totalFields += 1

        // GPS coordinates
        if gpsLat != nil && gpsLon != nil { score += 1.0 }
        totalFields += 1

        // Camera model
        if cameraModel != nil { score += 1.0 }
        totalFields += 1

        // Keywords/tags
        if keywords != nil || tags != nil { score += 1.0 }
        totalFields += 1

        return totalFields > 0 ? score / Double(totalFields) : 0.0
    }

    /// Get format preference score (RAW/PNG > JPEG > HEIC)
    public var formatPreferenceScore: Double {
        guard let utType = inferredUTType else { return 0.0 }

        // RAW formats get highest score
        if utType.contains("raw") || utType.contains("cr2") || utType.contains("nef") ||
           utType.contains("dng") || utType.contains("arw") {
            return 1.0
        }

        // PNG gets high score
        if utType.contains("png") {
            return 0.9
        }

        // JPEG gets medium score
        if utType.contains("jpeg") || utType.contains("jpg") {
            return 0.7
        }

        // HEIC gets lower score
        if utType.contains("heic") || utType.contains("heif") {
            return 0.5
        }

        return 0.0
    }
}

// MARK: - Path Identity

/// String-level canonical path for comparisons. Collapses symlinks,
/// `.`/`..` components, and trailing slashes so that two paths
/// referring to the same filesystem location via different string
/// representations compare equal.
///
/// **Scope**: This is string canonicalization, not file identity.
/// It does not unify hard links (different paths, same inode),
/// case-insensitive equivalents on APFS, Unicode normalization
/// variants, or security-scoped URL representations. For caches,
/// set membership, and "did I already process this path" checks,
/// `PathIdentity` is the right tool. For destructive operations
/// where physical file identity matters (merge safety, keeper
/// assertions), prefer content fingerprints or resource identifiers.
public enum PathIdentity {
    /// Canonical path string for identity comparisons.
    public static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Canonical path string from a path string.
    public static func canonical(_ path: String) -> String {
        canonical(URL(fileURLWithPath: path))
    }

    /// Canonicalize a URL for use as an enumeration root.
    /// Resolves symlinks so children inherit the canonical namespace.
    public static func canonicalRoot(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
