import Foundation

/// Lightweight session metadata written by the CLI alongside NDJSON artifacts.
/// The app reads these to discover sessions without opening the CLI's SwiftData store.
public struct SessionManifest: Codable, Sendable {
    public let sessionId: UUID
    public let directoryPath: String
    public let startedAt: Date
    public let completedAt: Date?
    public let totalFiles: Int
    public let mediaFiles: Int
    public let duplicateGroups: Int
    public let artifactFileName: String  // e.g., "{uuid}.ndjson.gz"

    public init(
        sessionId: UUID,
        directoryPath: String,
        startedAt: Date,
        completedAt: Date?,
        totalFiles: Int,
        mediaFiles: Int,
        duplicateGroups: Int,
        artifactFileName: String
    ) {
        self.sessionId = sessionId
        self.directoryPath = directoryPath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.totalFiles = totalFiles
        self.mediaFiles = mediaFiles
        self.duplicateGroups = duplicateGroups
        self.artifactFileName = artifactFileName
    }

    /// Standard directory for session artifacts and manifests.
    public static func sessionsDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Deduper")
            .appendingPathComponent("sessions")
    }

    /// Manifest file path for a given session ID.
    public static func manifestPath(for sessionId: UUID) -> URL {
        sessionsDirectory()
            .appendingPathComponent("\(sessionId.uuidString).manifest.json")
    }

    /// Write this manifest to its standard location.
    public func write() throws {
        let dir = Self.sessionsDirectory()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.manifestPath(for: sessionId))
    }

    /// Read a manifest from a file URL.
    public static func read(from url: URL) throws -> SessionManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self, from: data)
    }
}
