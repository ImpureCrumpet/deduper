import Foundation
import SwiftData
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
    /// JSON-encoded scan results for session recovery.
    /// Stores [ScanResultEntry] -- lightweight file list with group membership.
    public var resultsJSON: Data?

    public init(
        sessionId: UUID = UUID(),
        directoryPath: String,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        totalFiles: Int = 0,
        mediaFiles: Int = 0,
        duplicateGroups: Int = 0,
        resultsJSON: Data? = nil
    ) {
        self.sessionId = sessionId
        self.directoryPath = directoryPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.totalFiles = totalFiles
        self.mediaFiles = mediaFiles
        self.duplicateGroups = duplicateGroups
        self.resultsJSON = resultsJSON
    }
}

/// Lightweight representation of a duplicate group stored in ScanSession.resultsJSON.
public struct StoredDuplicateGroup: Codable, Sendable {
    public let groupId: UUID
    public let confidence: Double
    public let keeperPath: String?
    public let memberPaths: [String]
    public let mediaType: Int16

    public init(
        groupId: UUID,
        confidence: Double,
        keeperPath: String?,
        memberPaths: [String],
        mediaType: Int16
    ) {
        self.groupId = groupId
        self.confidence = confidence
        self.keeperPath = keeperPath
        self.memberPaths = memberPaths
        self.mediaType = mediaType
    }

    public init(
        from group: DuplicateGroupResult,
        fileMap: [UUID: URL]
    ) {
        self.groupId = group.groupId
        self.confidence = group.confidence
        self.keeperPath = group.keeperSuggestion.flatMap {
            fileMap[$0]?.path
        }
        self.memberPaths = group.members.compactMap {
            fileMap[$0.fileId]?.path
        }
        self.mediaType = group.mediaType.rawValue
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

    public init(
        filePath: String,
        fileSize: Int64,
        modifiedAt: Date? = nil,
        hashAlgorithm: String,
        perceptualHash: String,
        computedAt: Date = Date()
    ) {
        self.filePath = filePath
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.hashAlgorithm = hashAlgorithm
        self.perceptualHash = perceptualHash
        self.computedAt = computedAt
    }
}

// MARK: - Hash Cache Service

/// Provides incremental scanning by caching perceptual hashes in SwiftData.
/// Files are looked up by path + size + mtime; if unchanged, cached hashes are reused.
public actor HashCacheService {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
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
        var descriptor = FetchDescriptor<HashedFile>(predicate: predicate)
        descriptor.fetchLimit = 10

        guard let results = try? context.fetch(descriptor),
              !results.isEmpty else {
            return nil
        }

        // Validate that size and mtime match
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

    /// Store hashes for a file in the cache.
    @MainActor
    public func store(
        path: String,
        fileSize: Int64,
        modifiedAt: Date?,
        hashes: [(algorithm: String, hash: UInt64)]
    ) {
        let context = ModelContext(container)

        // Delete existing entries for this path
        let predicate = #Predicate<HashedFile> {
            $0.filePath == path
        }
        let descriptor = FetchDescriptor<HashedFile>(predicate: predicate)
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
                perceptualHash: String(h.hash, radix: 16)
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
        return try ModelContainer(for: schema, configurations: [config])
    }
}
