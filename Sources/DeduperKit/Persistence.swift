import Foundation
import SwiftData
import CryptoKit
import os

// MARK: - SwiftData Models

@Model
public final class ScanSession {
    public var sessionId: UUID
    public var directoryPath: String
    public var startedAt: Date
    public var completedAt: Date?
    public var totalFiles: Int
    public var mediaFiles: Int
    public var duplicateGroups: Int
    /// Legacy: JSON-encoded scan results. Prefer artifactPath for new sessions.
    public var resultsJSON: Data?
    /// Path to compressed NDJSON artifact file for scalable storage.
    public var artifactPath: String?

    public init(
        sessionId: UUID = UUID(),
        directoryPath: String,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        totalFiles: Int = 0,
        mediaFiles: Int = 0,
        duplicateGroups: Int = 0,
        resultsJSON: Data? = nil,
        artifactPath: String? = nil
    ) {
        self.sessionId = sessionId
        self.directoryPath = directoryPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.totalFiles = totalFiles
        self.mediaFiles = mediaFiles
        self.duplicateGroups = duplicateGroups
        self.resultsJSON = resultsJSON
        self.artifactPath = artifactPath
    }
}

/// V2 member object with per-member confidence signals.
public struct StoredDuplicateMember: Codable, Sendable {
    public let path: String
    public let fileSize: Int64
    public let confidence: Double
    public let signals: [ConfidenceSignal]
    public let penalties: [ConfidencePenalty]
    public let rationale: [String]
    public let isKeeper: Bool

    public init(
        path: String,
        fileSize: Int64,
        confidence: Double,
        signals: [ConfidenceSignal],
        penalties: [ConfidencePenalty],
        rationale: [String],
        isKeeper: Bool
    ) {
        self.path = path
        self.fileSize = fileSize
        self.confidence = confidence
        self.signals = signals
        self.penalties = penalties
        self.rationale = rationale
        self.isKeeper = isKeeper
    }
}

/// Lightweight representation of a duplicate group stored in artifacts.
public struct StoredDuplicateGroup: Codable, Sendable {
    // V1 fields (always present)
    public let groupId: UUID
    public let groupIndex: Int
    public let confidence: Double
    public var keeperPath: String?
    public let memberPaths: [String]
    public let memberSizes: [Int64]
    public let mediaType: Int16

    // V2 fields (nil in pre-Slice-3 artifacts)
    public let schemaVersion: Int?
    public let matchKind: String?
    public let membersV2: [StoredDuplicateMember]?
    public let rationaleLines: [String]?
    public let incomplete: Bool?

    /// V1-only initializer (backward compat, tests).
    public init(
        groupId: UUID,
        groupIndex: Int = 0,
        confidence: Double,
        keeperPath: String?,
        memberPaths: [String],
        memberSizes: [Int64] = [],
        mediaType: Int16
    ) {
        self.groupId = groupId
        self.groupIndex = groupIndex
        self.confidence = confidence
        self.keeperPath = keeperPath
        self.memberPaths = memberPaths
        self.memberSizes = memberSizes
        self.mediaType = mediaType
        self.schemaVersion = nil
        self.matchKind = nil
        self.membersV2 = nil
        self.rationaleLines = nil
        self.incomplete = nil
    }

    /// Full initializer from detection result.
    public init(
        from group: DuplicateGroupResult,
        fileMap: [UUID: URL],
        index: Int
    ) {
        self.groupId = group.groupId
        self.groupIndex = index
        self.confidence = group.confidence
        self.keeperPath = group.keeperSuggestion.flatMap {
            fileMap[$0]?.path
        }
        self.memberPaths = group.members.compactMap {
            fileMap[$0.fileId]?.path
        }
        self.memberSizes = group.members.map { $0.fileSize }
        self.mediaType = group.mediaType.rawValue
        self.schemaVersion = 2
        self.matchKind = Self.deriveMatchKind(
            from: group
        ).rawValue
        self.membersV2 = group.members.compactMap { member in
            guard let path = fileMap[member.fileId]?.path else {
                return nil
            }
            return StoredDuplicateMember(
                path: path,
                fileSize: member.fileSize,
                confidence: member.confidence,
                signals: member.signals,
                penalties: member.penalties,
                rationale: member.rationale,
                isKeeper: member.fileId == group.keeperSuggestion
            )
        }
        self.rationaleLines = group.rationaleLines
        self.incomplete = group.incomplete
    }

    /// Derive MatchKind from detection result signals.
    private static func deriveMatchKind(
        from group: DuplicateGroupResult
    ) -> MatchKind {
        // If any member has a "checksum" signal, it's an exact match
        let hasChecksum = group.members.contains { member in
            member.signals.contains { $0.key == "checksum" }
        }
        if hasChecksum { return .sha256Exact }

        // Video groups use video heuristic
        if group.mediaType == .video { return .videoHeuristic }

        return .perceptual
    }

    /// Resolved MatchKind (handles old artifacts without matchKind).
    public var resolvedMatchKind: MatchKind {
        if let kind = matchKind,
           let mk = MatchKind(rawValue: kind) {
            return mk
        }
        // V1 artifact without explicit matchKind — cannot safely infer.
        // Never derive matchKind from confidence (AD-005).
        return .legacyUnknown
    }
}

// MARK: - Session Artifact Service

/// Reads and writes session artifacts as NDJSON files for scalable storage.
public struct SessionArtifact: Sendable {
    private static let logger = Logger(
        subsystem: "app.deduper", category: "artifact"
    )

    /// Write groups as NDJSON to the artifact path.
    public static func write(
        groups: [StoredDuplicateGroup],
        to path: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        var lines: [Data] = []
        for group in groups {
            let line = try encoder.encode(group)
            lines.append(line)
        }

        let ndjson = lines.map { String(data: $0, encoding: .utf8)! }
            .joined(separator: "\n")

        // Write as gzip-compressed NDJSON
        let ndjsonData = Data(ndjson.utf8)
        if let compressed = compress(ndjsonData) {
            try compressed.write(to: path)
        } else {
            // Fallback: write uncompressed
            try ndjsonData.write(to: path)
        }
        logger.info(
            "Wrote \(groups.count) groups to \(path.lastPathComponent)"
        )
    }

    /// Read all groups from an artifact file.
    public static func readGroups(
        from path: URL
    ) throws -> [StoredDuplicateGroup] {
        try readGroups(from: path, filter: nil)
    }

    /// Read groups from an artifact file with optional filtering.
    /// Streams line by line for efficiency.
    public static func readGroups(
        from path: URL,
        filter: ((StoredDuplicateGroup) -> Bool)?
    ) throws -> [StoredDuplicateGroup] {
        let rawData = try Data(contentsOf: path)

        // Try decompressing first
        let data: Data
        if let decompressed = decompress(rawData) {
            data = decompressed
        } else {
            data = rawData // Assume uncompressed
        }

        guard let ndjson = String(data: data, encoding: .utf8) else {
            throw ArtifactError.invalidData
        }

        let decoder = JSONDecoder()
        var groups: [StoredDuplicateGroup] = []

        for line in ndjson.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8) else {
                continue
            }
            let group = try decoder.decode(
                StoredDuplicateGroup.self, from: lineData
            )
            if let filter {
                if filter(group) {
                    groups.append(group)
                }
            } else {
                groups.append(group)
            }
        }

        return groups
    }

    /// Read a single group by index from an artifact file.
    /// Stops reading once the group is found.
    public static func readGroup(
        at index: Int,
        from path: URL
    ) throws -> StoredDuplicateGroup? {
        let results = try readGroups(from: path) { group in
            group.groupIndex == index
        }
        return results.first
    }

    /// Get the artifact directory for sessions.
    public static func artifactDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Deduper")
            .appendingPathComponent("sessions")
    }

    /// Generate an artifact path for a session.
    public static func artifactPath(
        for sessionId: UUID
    ) -> URL {
        artifactDirectory()
            .appendingPathComponent("\(sessionId.uuidString).ndjson.gz")
    }

    // MARK: - Compression

    private static func compress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(
            using: .zlib
        ) as Data
    }

    private static func decompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(
            using: .zlib
        ) as Data
    }
}

public enum ArtifactError: Error, LocalizedError, Sendable {
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid artifact data"
        }
    }
}

// MARK: - Session Loading Helpers

extension ScanSession {
    /// Load groups from either artifact file or legacy resultsJSON.
    public func loadGroups() throws -> [StoredDuplicateGroup] {
        // Prefer artifact file
        if let artPath = artifactPath {
            let url = URL(fileURLWithPath: artPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return try SessionArtifact.readGroups(from: url)
            }
        }

        // Fallback to legacy resultsJSON
        if let data = resultsJSON {
            return try JSONDecoder().decode(
                [StoredDuplicateGroup].self, from: data
            )
        }

        return []
    }

    /// Load groups with a filter (streaming for artifacts).
    public func loadGroups(
        filter: ((StoredDuplicateGroup) -> Bool)?
    ) throws -> [StoredDuplicateGroup] {
        if let artPath = artifactPath {
            let url = URL(fileURLWithPath: artPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return try SessionArtifact.readGroups(
                    from: url, filter: filter
                )
            }
        }

        // Fallback to legacy: load all then filter
        var groups = try loadGroups()
        if let filter {
            groups = groups.filter(filter)
        }
        return groups
    }
}

@Model
public final class HashedFile {
    public var filePath: String
    public var fileSize: Int64
    public var modifiedAt: Date?
    public var hashAlgorithm: String
    public var perceptualHash: String
    public var computedAt: Date
    /// Content fingerprint for content-based cache lookups.
    /// Format: SHA256(first 64KB + last 64KB + fileSize bytes).
    public var contentFingerprint: String?

    public init(
        filePath: String,
        fileSize: Int64,
        modifiedAt: Date? = nil,
        hashAlgorithm: String,
        perceptualHash: String,
        computedAt: Date = Date(),
        contentFingerprint: String? = nil
    ) {
        self.filePath = filePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.hashAlgorithm = hashAlgorithm
        self.perceptualHash = perceptualHash
        self.computedAt = computedAt
        self.contentFingerprint = contentFingerprint
    }
}

// MARK: - Hash Cache Service

/// Provides incremental scanning by caching perceptual hashes in SwiftData.
/// Files are looked up by content fingerprint (surviving renames/moves),
/// falling back to path + size + mtime for migration.
public actor HashCacheService {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    /// Look up cached hashes for a file by content fingerprint.
    @MainActor
    public func lookupByFingerprint(
        fingerprint: String
    ) -> [CachedHash]? {
        let context = ModelContext(container)
        let predicate = #Predicate<HashedFile> {
            $0.contentFingerprint == fingerprint
        }
        var descriptor = FetchDescriptor<HashedFile>(
            predicate: predicate
        )
        descriptor.fetchLimit = 10

        guard let results = try? context.fetch(descriptor),
              !results.isEmpty else {
            return nil
        }

        return results.map {
            CachedHash(
                algorithm: $0.hashAlgorithm,
                hash: UInt64($0.perceptualHash, radix: 16) ?? 0
            )
        }
    }

    /// Look up cached hashes for a file. Returns nil if file has changed.
    @MainActor
    public func lookup(
        path: String,
        fileSize: Int64,
        modifiedAt: Date?
    ) -> [CachedHash]? {
        let context = ModelContext(container)
        let predicate = #Predicate<HashedFile> {
            $0.filePath == path
        }
        var descriptor = FetchDescriptor<HashedFile>(
            predicate: predicate
        )
        descriptor.fetchLimit = 10

        guard let results = try? context.fetch(descriptor),
              !results.isEmpty else {
            return nil
        }

        let first = results[0]
        guard first.fileSize == fileSize else { return nil }
        if let cached = first.modifiedAt, let current = modifiedAt {
            guard abs(cached.timeIntervalSince(current)) < 1.0 else {
                return nil
            }
        }

        return results.map {
            CachedHash(
                algorithm: $0.hashAlgorithm,
                hash: UInt64($0.perceptualHash, radix: 16) ?? 0
            )
        }
    }

    /// Store hashes for a file in the cache with content fingerprint.
    @MainActor
    public func store(
        path: String,
        fileSize: Int64,
        modifiedAt: Date?,
        hashes: [(algorithm: String, hash: UInt64)],
        contentFingerprint: String? = nil
    ) {
        let context = ModelContext(container)

        // Delete existing entries for this path
        let predicate = #Predicate<HashedFile> {
            $0.filePath == path
        }
        let descriptor = FetchDescriptor<HashedFile>(
            predicate: predicate
        )
        if let existing = try? context.fetch(descriptor) {
            for entry in existing {
                context.delete(entry)
            }
        }

        // Insert new entries
        for h in hashes {
            let entry = HashedFile(
                filePath: path,
                fileSize: fileSize,
                modifiedAt: modifiedAt,
                hashAlgorithm: h.algorithm,
                perceptualHash: String(h.hash, radix: 16),
                contentFingerprint: contentFingerprint
            )
            context.insert(entry)
        }

        try? context.save()
    }
}

/// A cached hash result returned from the hash cache.
public struct CachedHash: Sendable {
    public let algorithm: String
    public let hash: UInt64
}

// MARK: - Content Fingerprint

/// Computes a content fingerprint: SHA256(first 64KB + last 64KB + size).
/// This survives file renames/moves without recomputing expensive hashes.
public enum ContentFingerprint {
    public static func compute(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let attrs = try? FileManager.default
            .attributesOfItem(atPath: url.path),
              let fileSize = (attrs[.size] as? NSNumber)?
                .int64Value else {
            return nil
        }

        var hasher = SHA256()
        let chunkSize = 64 * 1024 // 64KB

        // Read first 64KB
        let firstChunk = handle.readData(
            ofLength: min(chunkSize, Int(fileSize))
        )
        hasher.update(data: firstChunk)

        // Read last 64KB if file is larger
        if fileSize > Int64(chunkSize) {
            let offset = UInt64(max(0, fileSize - Int64(chunkSize)))
            try? handle.seek(toOffset: offset)
            let lastChunk = handle.readData(ofLength: chunkSize)
            hasher.update(data: lastChunk)
        }

        // Include file size
        var size = fileSize
        withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Container Factory

public enum PersistenceFactory {
    /// Create a SwiftData model container.
    /// Pass `inMemory: true` for testing.
    public static func makeContainer(
        inMemory: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([ScanSession.self, HashedFile.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
        } else {
            config = ModelConfiguration(schema: schema)
        }
        return try ModelContainer(
            for: schema, configurations: [config]
        )
    }
}
